const std = @import("std");
const events = @import("event_runtime");
const battle = @import("opening_battle");
const data = @import("opening_assets").battles;
const engine = @import("battle");
const combat = @import("combat_session");
const field = @import("field");

const allocator = std.testing.allocator;

fn load() !std.json.Parsed(battle.Asset) {
    return battle.open(allocator, data.json);
}

fn admittedStory() events.StoryState {
    var story = events.StoryState{};
    story.scenario[4] = 1;
    return story;
}

test "asset hash and one-BonBon formation are source pinned" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var parsed = try load();
    defer parsed.deinit();
    const enemy = parsed.value.formation.enemies[0];
    try std.testing.expectEqualStrings("BonBon", enemy.name);
    try std.testing.expectEqual(@as(u16, 18), enemy.hp);
    try std.testing.expectEqual(@as(i32, -128), enemy.world[0]);
}

test "all three source entries resolve the same encounter" {
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.entries.len);
    for (parsed.value.entries) |entry| {
        try std.testing.expectEqualStrings("area_a.encounter.01", entry.encounter_id);
        try std.testing.expect(entry.pre_effect_offset < entry.trigger_offset);
    }
}

test "guard failure consumes no story effect" {
    var parsed = try load();
    defer parsed.deinit();
    var story = events.StoryState{};
    try std.testing.expectError(error.BattleGuardFailed, battle.begin(parsed.value.entries[0], &story));
    try std.testing.expect(std.mem.allEqual(u8, &story.scenario, 0));
}

test "admission publishes the pre-battle mask exactly once" {
    var parsed = try load();
    defer parsed.deinit();
    var story = admittedStory();
    _ = try battle.begin(parsed.value.entries[0], &story);
    try std.testing.expectEqual(@as(u8, 8), story.scenario[34]);
    for (parsed.value.entries) |entry| try std.testing.expectError(error.BattleGuardFailed, battle.begin(entry, &story));
}

test "victory returns without auto-chaining another battle" {
    var parsed = try load();
    defer parsed.deinit();
    var story = admittedStory();
    var session = try battle.begin(parsed.value.entries[0], &story);
    try battle.settle(&session, .victory);
    try std.testing.expectEqual(battle.Outcome.victory_returned, session.outcome);
    try std.testing.expectEqualStrings(parsed.value.entries[0].id, session.entry_id);
}

test "defeat is not victory or story success" {
    var parsed = try load();
    defer parsed.deinit();
    var story = admittedStory();
    var session = try battle.begin(parsed.value.entries[0], &story);
    try battle.settle(&session, .defeat);
    try std.testing.expectEqual(battle.Outcome.defeat_game_over, session.outcome);
    try std.testing.expectEqual(@as(u8, 8), story.scenario[34]);
}

test "escape is an explicit blocker and duplicate settlement is rejected" {
    var parsed = try load();
    defer parsed.deinit();
    var story = admittedStory();
    var session = try battle.begin(parsed.value.entries[0], &story);
    try std.testing.expectError(error.UnsupportedEscapeContinuation, battle.settle(&session, .escape));
    try std.testing.expectEqual(battle.Outcome.unsettled, session.outcome);
    try battle.settle(&session, .victory);
    try std.testing.expectError(error.DuplicateSettlement, battle.settle(&session, .defeat));
}

test "stale formation and entry identities fail closed" {
    var parsed = try load();
    defer parsed.deinit();
    var bad = parsed.value;
    const enemies = try allocator.dupe(battle.Enemy, bad.formation.enemies);
    defer allocator.free(enemies);
    enemies[0].hp = 1;
    bad.formation.enemies = enemies;
    try std.testing.expectError(error.InvalidBattleFormation, battle.validate(bad));
    bad = parsed.value;
    bad.coverage.battle_entries = 2;
    try std.testing.expectError(error.InvalidBattleCoverage, battle.validate(bad));
}

const Fixture = struct {
    content: std.json.Parsed(engine.Content),
    items: std.json.Parsed(field.items.Rules),
    members: [6]engine.Member = undefined,
    scratch: [6]engine.Member = undefined,
    source: engine.State = undefined,
    profiles: []engine.Profile = &.{},
    fingerprint: [64]u8 = undefined,
    tape: [8192]u15 = undefined,
    cursor: usize = 0,

    fn open() !Fixture {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/journey_battle.json", allocator, .limited(1024 * 1024));
        defer allocator.free(bytes);
        var result: Fixture = .{
            .content = try engine.load(allocator, bytes),
            .items = try field.items.load(allocator, field.items.json),
        };
        errdefer result.deinit();
        result.profiles = try allocator.dupe(engine.Profile, result.content.value.enemies);
        result.profiles[0].target_policy = .random;
        result.content.value.enemies = result.profiles;
        for (&result.tape, 0..) |*value, index| value.* = @intCast((index * 37 + 11) % 32767);
        return result;
    }

    fn initialize(self: *Fixture) !void {
        self.source = try engine.State.init(self.content.value, self.items.value, &self.members, 17);
    }

    fn deinit(self: *Fixture) void {
        if (self.profiles.len != 0) allocator.free(self.profiles);
        self.items.deinit();
        self.content.deinit();
    }

    fn draws(self: *Fixture) engine.systems.Draws {
        return .{ .values = &self.tape, .cursor = self.cursor };
    }

    fn begin(self: *Fixture, asset: battle.Asset, entry: battle.Entry, story: *events.StoryState) !battle.CombatCaller {
        self.fingerprint = try combat.fingerprint(self.source);
        return battle.CombatCaller.begin(asset, entry, story, self.source, &self.scratch, self.draws(), "area_a_1", .{
            .id = entry.id,
            .receipt = "1",
            .content_id = "journey_battle",
            .encounter_id = entry.encounter_id,
            .content_fingerprint = &self.fingerprint,
        });
    }

    fn tick(self: *Fixture, caller: *battle.CombatCaller, input: engine.Input) !void {
        var current = self.draws();
        try caller.tick(input, &current);
        self.cursor = current.cursor;
    }
};

const DriveMode = enum { attack, defend, escape };

fn queueRound(state: *engine.State, attack: bool) !void {
    const first = for (0..state.partyCount()) |index| {
        if (state.participates(index)) break index;
    } else return error.NoLivingPartyMember;
    state.choose(first);
    var guard: usize = 0;
    while (state.phase == .command and guard < 12) : (guard += 1) {
        if (attack and state.canAttackTarget(state.actor, 0)) {
            state.queue(.{ .attack = 0 });
        } else {
            state.queue(.defend);
        }
    }
    if (state.phase != .confirm_round) return error.RoundNotQueued;
}

fn drive(fixture: *Fixture, caller: *battle.CombatCaller, mode: DriveMode) !void {
    for (0..4000) |_| {
        switch (caller.session.state.phase) {
            .victory, .defeat, .escaped => return,
            .intro => try fixture.tick(caller, .{ .confirm = true }),
            .battle_menu => if (mode == .escape and caller.session.state.selection != 1) {
                try fixture.tick(caller, .{ .down = true });
            } else {
                try fixture.tick(caller, .{ .confirm = true });
            },
            .command => try queueRound(&caller.session.state, mode == .attack),
            .confirm_round => try fixture.tick(caller, .{ .confirm = true }),
            else => try fixture.tick(caller, .{}),
        }
    }
    return error.CombatDidNotSettle;
}

test "all three source entries start the real one-BonBon combat session" {
    var parsed = try load();
    defer parsed.deinit();
    var fixture = try Fixture.open();
    defer fixture.deinit();
    try fixture.initialize();
    for (parsed.value.entries) |entry| {
        var story = admittedStory();
        const caller = try fixture.begin(parsed.value, entry, &story);
        try std.testing.expectEqual(engine.Phase.battle_menu, caller.session.state.phase);
        try std.testing.expectEqual(@as(u16, 18), caller.session.state.enemy_hp[0]);
        try std.testing.expectEqualStrings(entry.id, caller.planner.entry_id);
        try std.testing.expectEqualStrings("area_a_1", caller.session.entry.encounter_id);
    }
}

test "production guard failure and stale combat binding leave story untouched" {
    var parsed = try load();
    defer parsed.deinit();
    var fixture = try Fixture.open();
    defer fixture.deinit();
    try fixture.initialize();
    var story = events.StoryState{};
    try std.testing.expectError(error.BattleGuardFailed, fixture.begin(parsed.value, parsed.value.entries[0], &story));
    try std.testing.expect(std.mem.allEqual(u8, &story.scenario, 0));

    story = admittedStory();
    const profiles = try allocator.dupe(engine.Profile, fixture.source.content.enemies);
    defer allocator.free(profiles);
    profiles[0].max_hp = 17;
    fixture.source.content.enemies = profiles;
    try std.testing.expectError(error.MissingOpeningBattleBinding, fixture.begin(parsed.value, parsed.value.entries[0], &story));
    try std.testing.expectEqual(@as(u8, 0), story.scenario[34]);
}

test "real combat victory commits once and returns after the source trigger" {
    var parsed = try load();
    defer parsed.deinit();
    var fixture = try Fixture.open();
    defer fixture.deinit();
    try fixture.initialize();
    var story = admittedStory();
    const entry = parsed.value.entries[1];
    var caller = try fixture.begin(parsed.value, entry, &story);
    const money = caller.source.progress.money;
    try drive(&fixture, &caller, .attack);
    try std.testing.expectEqual(engine.Phase.victory, caller.session.state.phase);
    try std.testing.expect(caller.session.state.rewardReady());
    const settlement = try caller.settle(fixture.draws());
    try std.testing.expectEqual(battle.Outcome.victory_returned, settlement.outcome);
    const continuation = settlement.continuation.?;
    try std.testing.expectEqualStrings(entry.id, continuation.entry_id);
    try std.testing.expectEqual(entry.stream, continuation.stream);
    try std.testing.expectEqual(entry.trigger_offset, continuation.trigger_offset);
    try std.testing.expectEqual(entry.trigger_offset + 2, continuation.resume_offset);
    try std.testing.expect(caller.source.progress.money > money);
    try std.testing.expect(caller.session.finished);
    try std.testing.expectError(error.DuplicateSettlement, caller.settle(fixture.draws()));
}

test "real combat defeat is game over without a source continuation" {
    var parsed = try load();
    defer parsed.deinit();
    var fixture = try Fixture.open();
    defer fixture.deinit();
    try fixture.initialize();
    var story = admittedStory();
    var caller = try fixture.begin(parsed.value, parsed.value.entries[2], &story);
    for (caller.session.state.progress.party) |*member| member.hp = 1;
    const money = caller.source.progress.money;
    try drive(&fixture, &caller, .defend);
    try std.testing.expectEqual(engine.Phase.defeat, caller.session.state.phase);
    const settlement = try caller.settle(fixture.draws());
    try std.testing.expectEqual(battle.Outcome.defeat_game_over, settlement.outcome);
    try std.testing.expect(settlement.continuation == null);
    try std.testing.expectEqual(money, caller.source.progress.money);
    try std.testing.expect(caller.session.finished);
}

test "real combat escape remains unsettled and cannot return to the stream" {
    var parsed = try load();
    defer parsed.deinit();
    var fixture = try Fixture.open();
    defer fixture.deinit();
    try fixture.initialize();
    var story = admittedStory();
    var caller = try fixture.begin(parsed.value, parsed.value.entries[0], &story);
    const money = caller.source.progress.money;
    try drive(&fixture, &caller, .escape);
    try std.testing.expectEqual(engine.Phase.escaped, caller.session.state.phase);
    try std.testing.expectError(error.UnsupportedEscapeContinuation, caller.settle(fixture.draws()));
    try std.testing.expectEqual(battle.Outcome.unsettled, caller.planner.outcome);
    try std.testing.expect(!caller.session.finished);
    try std.testing.expectEqual(money, caller.source.progress.money);
}
