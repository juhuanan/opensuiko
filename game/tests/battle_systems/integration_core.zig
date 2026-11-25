const std = @import("std");
const h = @import("helpers.zig");
const allocator = h.allocator;
const hostFixture = h.hostFixture;
const Fixture = h.Fixture;
const battle = h.battle;
const rules = h.rules;
const field = h.field;
const battle_systems = h.battle_systems;
const host_mod = h.host_mod;
const world_battle = h.world_battle;
const combat_session = h.combat_session;
const spells_mod = h.spells_mod;
const techniques_mod = h.techniques_mod;
const unite_mod = h.unite_mod;
const outcomes_mod = h.outcomes_mod;
const firstLiving = h.firstLiving;
const Tape = h.Tape;
const queueRound = h.queueRound;
const tickToVictory = h.tickToVictory;
const stateBytes = h.stateBytes;
const sourceRoundBoundary = h.sourceRoundBoundary;

fn sourceDoubleBeat(combat: *battle.State, data: world_battle.Data, art: battle.world_art.Data, actor: usize, target: usize) void {
    combat.content.enemies = data.enemies;
    combat.content.encounters = data.encounters;
    combat.content.party_attacks = data.party_attacks;
    combat.content.world_art = art;
    combat.encounter = for (data.encounters, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, art.encounter)) break i;
    } else unreachable;
    combat.startEncounter();
    combat.active = null;
    combat.phase = .resolving;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = actor };
    combat.acted = @splat(true);
    combat.acted[actor] = false;
    combat.actions = @splat(.defend);
    combat.actions[actor] = .{ .attack = target };
    combat.runes = @splat(null);
    combat.runes[actor] = combat.content.systems.?.runeIndex("double-beat").?;
    combat.base_stats[actor].attack = 100;
    combat.base_stats[actor].skill = 9999;
    combat.base_stats[actor].luck = 0;
    for (0..combat.enemyCount()) |enemy| combat.enemy_hp[enemy] = 20000;
}

test "Double-Beat source coordinator repeats five melee actors before home and retains the first reaction" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const b = try world_battle.load(allocator, world_battle.json);
    defer b.deinit();
    const c = try world_battle.load(allocator, world_battle.json_c);
    defer c.deinit();
    const b_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer b_art.deinit();
    const c_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer c_art.deinit();
    const Reference = struct {
        cases: []const struct { region: []const u8, actor: usize, current: usize, target: usize, origin: battle.Position, positions: []const battle.Position },
    };
    const reference = try std.json.parseFromSlice(Reference, allocator, @embedFile("../fixtures/double_beat_motion.json"), .{ .ignore_unknown_fields = true });
    defer reference.deinit();
    var checked: usize = 0;
    inline for (.{ .{ b.value, b_art.value }, .{ c.value, c_art.value } }) |pair| {
        for (reference.value.cases) |case| {
            if (!std.mem.eql(u8, case.region, if (pair[1].c_tracks == null) "b" else "c")) continue;
            const actor = case.actor;
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
            sourceDoubleBeat(&combat, pair[0], pair[1], actor, case.current);
            try std.testing.expect(combat.canFreeWill());
            const timing = combat.partyAttackTiming(actor).?;
            const home = pair[1].formation_slots[actor];
            const next = case.target;
            const charge_before = members[actor].rune_charges;
            const values: [6]u15 = @splat(51);
            var draws = rules.Draws{ .values = &values };
            var first_damage: u16 = 0;
            var origin = home;
            for (1..timing.return_tick + timing.release_tick + 1) |tick| {
                if (tick == timing.return_tick) origin = battle.world_art.actorSample(pair[1], &combat, actor).sample.position;
                try combat.tickReplay(.{}, &draws);
                if (tick == timing.impact_tick) {
                    first_damage = 20000 - combat.enemy_hp[case.current];
                    try std.testing.expect(first_damage > 0);
                }
                try std.testing.expectEqual(@as(u16, 20000) - (if (tick >= timing.impact_tick) first_damage else 0) - (if (next == case.current and tick >= timing.return_tick + timing.impact_tick) first_damage else 0), combat.enemy_hp[case.current]);
                if (next != case.current) try std.testing.expectEqual(@as(u16, 20000) - (if (tick >= timing.return_tick + timing.impact_tick) first_damage else 0), combat.enemy_hp[next]);
                const expected_draws: usize = if (tick < timing.impact_tick) 2 else if (tick < timing.return_tick) 3 else if (tick < timing.return_tick + timing.impact_tick) 5 else 6;
                try std.testing.expectEqual(expected_draws, draws.cursor);
                try std.testing.expectEqual(tick < timing.return_tick, combat.double_beat_pending[actor]);
                try std.testing.expectEqual(tick < timing.return_tick + timing.release_tick, combat.coordinatorLocked(actor));
                try std.testing.expectEqual(tick >= timing.return_tick and tick < timing.impact_tick + timing.target_release_delay, combat.party_strikes[6 + actor] != null);
                const visual = battle.world_art.actorSample(pair[1], &combat, actor).sample;
                if (tick == timing.return_tick) {
                    try std.testing.expectEqualDeep(origin, visual.position);
                    try std.testing.expectEqualDeep(case.origin, origin);
                    try std.testing.expectEqualDeep(origin, combat.party_strikes[actor].?.origin.?);
                    try std.testing.expect(!combat.party_strikes[actor].?.returning);
                    try std.testing.expectEqual(next + combat.partyCount(), combat.party_strikes[actor].?.target);
                }
                if (tick >= timing.return_tick and tick < timing.return_tick + timing.release_tick) {
                    const age: u16 = @intCast(tick - timing.return_tick);
                    try std.testing.expectEqualDeep(case.positions[age], visual.position);
                    if (age >= timing.motion.?.return_start + timing.motion.?.retreat.ticks) try std.testing.expectEqualDeep(home, visual.position);
                }
            }
            try std.testing.expectEqualDeep(charge_before, members[actor].rune_charges);
            for (combat.party_strikes) |strike| try std.testing.expect(strike == null);
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 15), checked);
}

test "Double-Beat source coordinator keeps a lethal first target's KO while striking the next" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const host = try hostFixture();
    defer host.deinit();
    const data = try world_battle.load(allocator, world_battle.json_c);
    defer data.deinit();
    const art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer art.deinit();
    const Case = enum { ordinary, unbalanced, protected, sleeping_target };
    for ([_]Case{ .ordinary, .unbalanced, .protected, .sleeping_target }) |case| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        sourceDoubleBeat(&combat, data.value, art.value, 0, 0);
        combat.enemy_hp[0] = 1;
        if (case == .unbalanced) {
            combat.integration = .{ .host = host };
            combat.content.round_start = data.value.round_start;
            var interrupted = combat;
            interrupted.unbalanced[0] = 2;
            var empty = rules.Draws{ .values = &.{} };
            try interrupted.tickReplay(.{}, &empty);
            try std.testing.expect(interrupted.acted[0] and interrupted.coordinator.?.completed);
            try std.testing.expect(interrupted.party_strikes[0] == null);
            try std.testing.expectEqual(@as(u16, 1), interrupted.enemy_hp[0]);
        }
        var simultaneous = [_]battle.PartyAttackTiming{combat.partyAttackTiming(0).?};
        if (case == .protected) {
            simultaneous[0].target_release_delay = simultaneous[0].return_tick - simultaneous[0].impact_tick;
            try simultaneous[0].validate();
            combat.content.party_attacks = &simultaneous;
        }
        const timing = combat.partyAttackTiming(0).?;
        const down = timing.impact_tick + timing.target_release_delay;
        const cleanup = down + combat.enemy(0).knockout_ticks.? - 1;
        const values: [6]u15 = @splat(51);
        var draws = rules.Draws{ .values = &values };
        const replacement = combat.partyCount() + 1;
        for (1..timing.return_tick + timing.release_tick + 1) |tick| {
            if (case == .unbalanced and tick == timing.return_tick) combat.unbalanced[0] = 2;
            if (case == .protected and tick == timing.return_tick + timing.impact_tick) combat.protection[replacement] = 2;
            if (case == .sleeping_target and tick == timing.return_tick) try std.testing.expect(combat.inflictStatus(replacement, .sleep));
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(tick >= timing.impact_tick, combat.enemy_hp[0] == 0);
            try std.testing.expectEqual(tick >= down, combat.enemyInactive(0));
            if (tick >= timing.return_tick) try std.testing.expectEqual(case != .unbalanced and tick < cleanup, combat.party_strikes[6] != null);
            const followup_damages = case == .ordinary or case == .sleeping_target;
            try std.testing.expectEqual(followup_damages and tick >= timing.return_tick + timing.impact_tick, combat.enemy_hp[1] < 20000);
        }
        for (combat.party_strikes) |strike| try std.testing.expect(strike == null);
        try std.testing.expectEqual(@as(usize, if (case == .unbalanced) 3 else 6), draws.cursor);
        if (case == .sleeping_target) try std.testing.expectEqual(@as(u8, 1), combat.asleep[replacement]);
        if (case == .unbalanced) {
            try std.testing.expectEqual(.battle_menu, combat.phase);
            try std.testing.expectEqual(@as(u8, 1), combat.unbalanced[0]);
        }
    }
}

test "Double-Beat source coordinator carries the latch and rolls back an exhausted repeat" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const data = try world_battle.load(allocator, world_battle.json_c);
    defer data.deinit();
    const art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer art.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    sourceDoubleBeat(&combat, data.value, art.value, 0, 0);
    const timing = combat.partyAttackTiming(0).?;
    const first: [3]u15 = @splat(51);
    var draws = rules.Draws{ .values = &first };
    for (1..timing.return_tick) |_| try combat.tickReplay(.{}, &draws);
    const before = try stateBytes(combat);
    defer allocator.free(before);
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    const after = try stateBytes(combat);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    try std.testing.expect(combat.double_beat_pending[0]);
    for ([_][]const u15{ &.{51}, &.{ 51, 0 } }) |failure| {
        draws = .{ .values = failure };
        const expected_error = if (failure.len == 1) error.RandomInputExhausted else error.UnsupportedCoordinatorAction;
        try std.testing.expectError(expected_error, combat.tickReplay(.{}, &draws));
        const unchanged = try stateBytes(combat);
        defer allocator.free(unchanged);
        try std.testing.expectEqualSlices(u8, before, unchanged);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    }
    const second: [3]u15 = @splat(51);
    draws = .{ .values = &second };
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.party_strikes[0].?.origin != null);
    try std.testing.expect(!combat.double_beat_pending[0]);

    var carried_members: [6]battle.Member = undefined;
    var carried = try battle.State.init(fixture.view, fixture.items.value, &carried_members, 17);
    sourceDoubleBeat(&carried, data.value, art.value, 0, 1);
    carried.double_beat_pending[0] = true;
    draws = .{ .values = &first };
    for (1..timing.release_tick + 1) |_| try carried.tickReplay(.{}, &draws);
    try std.testing.expect(!carried.double_beat_pending[0]);
    try std.testing.expectEqual(@as(u16, 20000), carried.enemy_hp[0]);
    try std.testing.expect(carried.enemy_hp[1] < 20000);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    try std.testing.expect(carried.party_strikes[0] == null);
}

test "Double-Beat source coordinator retains an unsuccessful latch through a lethal last target" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const data = try world_battle.load(allocator, world_battle.json);
    defer data.deinit();
    const art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer art.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    sourceDoubleBeat(&combat, data.value, art.value, 0, 0);
    combat.enemy_hp[0] = 1;
    const timing = combat.partyAttackTiming(0).?;
    const cleanup = timing.impact_tick + timing.target_release_delay + combat.enemy(0).knockout_ticks.? - 1;
    const values: [3]u15 = @splat(51);
    var draws = rules.Draws{ .values = &values };
    for (1..cleanup + 1) |tick| {
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.double_beat_pending[0]);
        try std.testing.expect(combat.party_strikes[6] == null);
        if (tick < timing.release_tick) try std.testing.expect(combat.coordinatorLocked(0)) else try std.testing.expect(!combat.coordinatorLocked(0));
    }
    try std.testing.expect(combat.party_strikes[0] == null);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
}

test "Double-Beat source motion validation preserves legacy clocks and rejects unsafe geometry" {
    const data = try world_battle.load(allocator, world_battle.json);
    defer data.deinit();
    const valid = data.value.party_attacks[0];
    try valid.validate();
    for (0..4) |fault| {
        var bad = valid;
        switch (fault) {
            0 => bad.motion.?.approach.ticks = 1,
            1 => bad.motion.?.approach.velocity.x = std.math.nan(f32),
            2 => bad.motion.?.return_start = bad.return_tick - 1,
            3 => bad.motion.?.retreat.ticks = 256,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidPartyAttackTiming, bad.validate());
    }
    var legacy = valid;
    legacy.motion = null;
    try legacy.validate();
    const bytes = try std.json.Stringify.valueAlloc(allocator, legacy, .{});
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "motion") == null);
}

test "Dodge B C misses follow source signals and integer geometry without critical damage or effect draws" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const b = try world_battle.load(allocator, world_battle.json);
    defer b.deinit();
    const c = try world_battle.load(allocator, world_battle.json_c);
    defer c.deinit();
    const b_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer b_art.deinit();
    const c_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer c_art.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    const Reference = struct {
        cases: []const struct { region: []const u8, actor: usize, target: usize, restored: bool, start: u16, retreat_start: u16, release: u16, samples: []const struct { position: battle.Position, pose: u16 } },
    };
    const reference = try std.json.parseFromSlice(Reference, allocator, @embedFile("../fixtures/physical_dodge_vectors.json"), .{ .ignore_unknown_fields = true });
    defer reference.deinit();
    var checked: usize = 0;
    inline for (.{ .{ b.value, b_art.value }, .{ c.value, c_art.value } }) |pair| {
        for (reference.value.cases) |case| {
            if (!std.mem.eql(u8, case.region, if (pair[1].c_tracks == null) "b" else "c")) continue;
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
            sourceDoubleBeat(&combat, pair[0], pair[1], case.actor, case.target);
            combat.runes[case.actor] = null;
            combat.roc_idle_at = 0;
            combat.roc_home_restored = case.restored;
            try combat.attachSpellScenes(&packet.value);
            const timing = combat.partyAttackTiming(case.actor).?;
            const target = combat.partyCount() + case.target;
            const before = members[case.actor].rune_charges;
            const values = [_]u15{99};
            var draws = rules.Draws{ .values = &values };
            for (1..@max(timing.release_tick, case.release) + 1) |tick| {
                try combat.tickReplay(.{}, &draws);
                try std.testing.expectEqual(@as(usize, 1), draws.cursor);
                try std.testing.expectEqual(@as(u16, 20000), combat.enemy_hp[case.target]);
                try std.testing.expectEqual(before, members[case.actor].rune_charges);
                try std.testing.expect(combat.actor_camera == null);
                try std.testing.expectEqual(@as(usize, 0), combat.spellSceneFrame().count);
                try std.testing.expect(combat.spellReaction(target) == null);
                try std.testing.expectEqual(tick < case.release, combat.coordinatorLocked(target));
                try std.testing.expectEqual(tick < timing.release_tick, combat.coordinatorLocked(case.actor));
                if (tick >= case.start) {
                    if (tick < case.release) {
                        const strike = combat.party_strikes[case.actor].?;
                        try std.testing.expect(strike.missed and !strike.critical);
                    }
                    try std.testing.expectEqual(case.retreat_start, combat.enemy(case.target).dodge.?.retreatStart(timing));
                    const actual = battle.world_art.actorSample(pair[1], &combat, target);
                    const expected = case.samples[tick - case.start];
                    try std.testing.expectEqualDeep(expected.position, actual.sample.position);
                    try std.testing.expectEqual(expected.pose, actual.sample.pose);
                }
            }
            try std.testing.expect(combat.party_strikes[case.actor] == null);
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 20), checked);
}

test "Dodge Double-Beat mixtures keep miss ordinary and critical draws with independent targets" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const b = try world_battle.load(allocator, world_battle.json);
    defer b.deinit();
    const c = try world_battle.load(allocator, world_battle.json_c);
    defer c.deinit();
    const b_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer b_art.deinit();
    const c_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer c_art.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var checked: usize = 0;
    inline for (.{ .{ b.value, b_art.value }, .{ c.value, c_art.value } }) |pair| {
        for ([_]usize{ 0, 1, 2, 4, 5 }) |actor| for (0..pair[1].enemy_positions.len) |target| for (0..9) |combination| {
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
            sourceDoubleBeat(&combat, pair[0], pair[1], actor, target);
            combat.roc_idle_at = 0;
            try combat.attachSpellScenes(&packet.value);
            const timing = combat.partyAttackTiming(actor).?;
            const next = (target + 1) % combat.enemyCount();
            const outcomes = [_]usize{ combination % 3, combination / 3 };
            const misses = [_]bool{ outcomes[0] == 2, outcomes[1] == 2 };
            var values: [6]u15 = undefined;
            var n: usize = 0;
            for (misses, outcomes) |miss, outcome| {
                values[n] = if (miss) 99 else 51;
                n += 1;
                if (!miss) {
                    values[n] = if (outcome == 1) 0 else 51;
                    values[n + 1] = 51;
                    n += 2;
                }
            }
            var draws = rules.Draws{ .values = values[0..n] };
            for (1..timing.return_tick + timing.release_tick + 1) |tick| {
                try combat.tickReplay(.{}, &draws);
                var cursor: usize = if (misses[0]) 1 else 2 + @as(usize, @intFromBool(tick >= timing.impact_tick));
                if (tick >= timing.return_tick) cursor += if (misses[1]) 1 else 2 + @as(usize, @intFromBool(tick >= timing.return_tick + timing.impact_tick));
                try std.testing.expectEqual(cursor, draws.cursor);
                for (0..combat.enemyCount()) |enemy| {
                    const amount = rules.physicalDamage(combat.stats(actor).attack, combat.stats(combat.partyCount() + enemy).defense, 51, false);
                    var hits: u32 = 0;
                    if (!misses[0] and tick >= timing.impact_tick and enemy == target) hits += if (outcomes[0] == 1) 3 else 1;
                    if (!misses[1] and tick >= timing.return_tick + timing.impact_tick and enemy == next) hits += if (outcomes[1] == 1) 3 else 1;
                    try std.testing.expectEqual(@as(u16, 20000) - @as(u16, @intCast(amount * hits)), combat.enemy_hp[enemy]);
                }
                if (tick == 1) try std.testing.expectEqual(misses[0], combat.party_strikes[actor].?.missed);
                if (tick == timing.return_tick) {
                    try std.testing.expectEqual(misses[1], combat.party_strikes[actor].?.missed);
                    try std.testing.expectEqual(next + combat.partyCount(), combat.party_strikes[actor].?.target);
                }
                for ([_]usize{ actor, 6 + actor }) |slot| if (combat.party_strikes[slot]) |strike| {
                    const anchor = if (strike.missed) timing.dodge_start_tick.? else timing.impact_tick;
                    try std.testing.expectEqual(strike.ticks >= anchor and strike.ticks < anchor + 30, strike.showsFeedback(timing));
                };
            }
            try std.testing.expectEqual(n, draws.cursor);
            try std.testing.expect(!combat.double_beat_pending[actor]);
            for (combat.party_strikes) |strike| try std.testing.expect(strike == null);
            checked += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 135), checked);
}

test "Dodge Spark latch and failed launch or follow-up restore both reaction lifetimes" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const data = try world_battle.load(allocator, world_battle.json_c);
    defer data.deinit();
    const art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer art.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    sourceDoubleBeat(&combat, data.value, art.value, 0, 0);
    const before = try stateBytes(combat);
    defer allocator.free(before);
    var empty = rules.Draws{ .values = &.{} };
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &empty));
    const after = try stateBytes(combat);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    const saved = combat.content.party_attacks;
    var legacy = try allocator.dupe(battle.PartyAttackTiming, saved);
    defer allocator.free(legacy);
    legacy[0].dodge_start_tick = null;
    combat.content.party_attacks = legacy;
    const refused = try stateBytes(combat);
    defer allocator.free(refused);
    var missing = rules.Draws{ .values = &.{99} };
    try std.testing.expectError(error.UnsupportedCoordinatorAction, combat.tickReplay(.{}, &missing));
    const still_legacy = try stateBytes(combat);
    defer allocator.free(still_legacy);
    try std.testing.expectEqualSlices(u8, refused, still_legacy);
    try std.testing.expectEqual(@as(usize, 0), missing.cursor);
    combat.content.party_attacks = saved;
    var draws = rules.Draws{ .values = &.{99} };
    const timing = combat.partyAttackTiming(0).?;
    for (1..timing.return_tick) |_| try combat.tickReplay(.{}, &draws);
    const waiting = try stateBytes(combat);
    defer allocator.free(waiting);
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    const unchanged = try stateBytes(combat);
    defer allocator.free(unchanged);
    try std.testing.expectEqualSlices(u8, waiting, unchanged);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
    try std.testing.expect(combat.double_beat_pending[0]);
    try std.testing.expect(combat.party_strikes[0].?.missed);
    try std.testing.expect(combat.party_strikes[6] == null);
    combat.runes[0] = combat.content.systems.?.runeIndex("spark").?;
    combat.party_strikes = @splat(null);
    combat.actions[0] = .{ .attack = 0 };
    combat.acted[0] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
    draws = .{ .values = &.{99} };
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.spark_pending and combat.party_strikes[0].?.missed);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
}

test "Dodge complete queued party rounds return to the menu and can repeat with settled recipients" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const b = try world_battle.load(allocator, world_battle.json);
    defer b.deinit();
    const c = try world_battle.load(allocator, world_battle.json_c);
    defer c.deinit();
    const b_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer b_art.deinit();
    const c_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer c_art.deinit();
    inline for (.{ .{ b.value, b_art.value }, .{ c.value, c_art.value } }) |pair| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        sourceDoubleBeat(&combat, pair[0], pair[1], 0, 0);
        combat.content.round_start = pair[0].round_start;
        combat.runes = @splat(null);
        combat.roc_idle_at = 0;
        const values: [4096]u15 = @splat(99);
        var draws = rules.Draws{ .values = &values };
        for (0..2) |_| {
            const round = combat.round;
            combat.phase = .resolving;
            combat.coordinator = .{ .stage = .select, .current_actor = 0, .remaining = 30, .completed = true };
            combat.acted = @splat(true);
            combat.actions = @splat(.defend);
            for ([_]usize{ 0, 1, 2, 4, 5 }) |actor| {
                combat.actions[actor] = .{ .attack = 0 };
                combat.acted[actor] = false;
            }
            var starts: usize = 0;
            for (0..1400) |_| {
                try combat.tickReplay(.{}, &draws);
                for (combat.party_strikes[0..6]) |maybe| if (maybe) |strike| {
                    if (strike.ticks == 1) {
                        try std.testing.expect(strike.missed);
                        starts += 1;
                    }
                };
                if (combat.phase == .battle_menu) break;
            }
            try std.testing.expectEqual(@as(usize, 5), starts);
            try std.testing.expectEqual(round + 1, combat.round);
            try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
            for (combat.party_strikes) |strike| try std.testing.expect(strike == null);
            for (combat.enemy_hp[0..combat.enemyCount()]) |hp| try std.testing.expectEqual(@as(u16, 20000), hp);
        }
    }
}

test "Dodge data rejects unsafe jumps and preserves omitted legacy fields" {
    const data = try world_battle.load(allocator, world_battle.json);
    defer data.deinit();
    const valid = for (data.value.enemies) |enemy| {
        if (std.mem.eql(u8, enemy.id, "roc")) break enemy;
    } else unreachable;
    try valid.dodge.?.validate();
    for (0..5) |fault| {
        var bad = valid.dodge.?;
        switch (fault) {
            0 => bad.back.ticks = 1,
            1 => bad.retreat.velocity.z = std.math.nan(f32),
            2 => bad.back.offset.x = 5000,
            3 => bad.ready_wait = 0,
            4 => bad.animation = 64,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidDodge, bad.validate());
    }
    var timing = data.value.party_attacks[0];
    timing.dodge_start_tick = timing.impact_tick;
    try std.testing.expectError(error.InvalidPartyAttackTiming, timing.validate());
    timing.dodge_start_tick = null;
    try timing.validate();
    const old_clock = try std.json.Stringify.valueAlloc(allocator, timing, .{});
    defer allocator.free(old_clock);
    try std.testing.expect(std.mem.indexOf(u8, old_clock, "dodge_start_tick") == null);
    var profile = valid;
    profile.dodge = null;
    const old_profile = try std.json.Stringify.valueAlloc(allocator, profile, .{});
    defer allocator.free(old_profile);
    try std.testing.expect(std.mem.indexOf(u8, old_profile, "\"dodge\":") == null);
}

test "Critical and ordinary B C hits retain source impact births damage and camera clocks" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const b = try world_battle.load(allocator, world_battle.json);
    defer b.deinit();
    const c = try world_battle.load(allocator, world_battle.json_c);
    defer c.deinit();
    const b_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer b_art.deinit();
    const c_art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer c_art.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    const Reference = struct {
        camera: struct { updates: u16, target: struct { position: [3]i32, angles: [3]i32, c: [3]i32, d: [3]i32 } },
        cases: []const struct { region: []const u8, actor: usize, target: usize, critical: bool, spawns: []const struct { at: u16, animation: u8, position_q12: [3]i32, center: [2]i8 } },
    };
    const reference = try std.json.parseFromSlice(Reference, allocator, @embedFile("../fixtures/physical_impact_vectors.json"), .{ .ignore_unknown_fields = true });
    defer reference.deinit();
    var checked: usize = 0;
    inline for (.{ .{ b.value, b_art.value }, .{ c.value, c_art.value } }) |pair| {
        for (reference.value.cases) |case| {
            if (!std.mem.eql(u8, case.region, if (pair[1].c_tracks == null) "b" else "c")) continue;
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
            sourceDoubleBeat(&combat, pair[0], pair[1], case.actor, case.target);
            combat.runes[case.actor] = null;
            combat.roc_idle_at = 0;
            combat.camera_ticks = 300;
            try combat.attachSpellScenes(&packet.value);
            const timing = combat.partyAttackTiming(case.actor).?;
            const damage = rules.physicalDamage(combat.stats(case.actor).attack, combat.stats(combat.partyCount() + case.target).defense, 51, false) * @as(u32, if (case.critical) 3 else 1);
            const values = [_]u15{ 51, if (case.critical) 0 else 51, 51 };
            var draws = rules.Draws{ .values = &values };
            var initial: [4][3]i32 = undefined;
            const launch_camera = battle.layout.currentCamera(combat);
            inline for (.{ "focus", "angles", "translation", "scale" }, 0..) |name, channel| {
                for (0..3) |axis| initial[channel][axis] = @field(launch_camera, name)[axis] * 4096;
            }
            for (1..timing.release_tick + 1) |tick| {
                try combat.tickReplay(.{}, &draws);
                try std.testing.expectEqual(@as(u16, 20000) - @as(u16, @intCast(if (tick >= timing.impact_tick) damage else 0)), combat.enemy_hp[case.target]);
                try std.testing.expectEqual(@as(usize, if (tick < timing.impact_tick) 2 else 3), draws.cursor);
                if (case.critical) {
                    const controller = combat.actor_camera.?;
                    var focus = reference.value.camera.target.position;
                    focus[0] = @intFromFloat(pair[1].enemy_positions[case.target].x * 4096);
                    focus[1] = @intFromFloat(pair[1].enemy_positions[case.target].y * 4096);
                    const destination = [_][3]i32{ focus, reference.value.camera.target.angles, reference.value.camera.target.c, reference.value.camera.target.d };
                    try std.testing.expectEqualDeep(destination, controller.target);
                    for (0..4) |channel| for (0..3) |axis| {
                        const age: i32 = @intCast(tick);
                        const expected = if (age <= 20) initial[channel][axis] + @divTrunc(destination[channel][axis] - initial[channel][axis], 20) * age else destination[channel][axis];
                        try std.testing.expectEqual(expected, controller.current[channel][axis]);
                    };
                } else try std.testing.expect(combat.actor_camera == null);
                const frame = combat.spellSceneFrame();
                var count: usize = 0;
                for (case.spawns, 0..) |spawn, i| {
                    if (tick < spawn.at) continue;
                    const clip = for (packet.value.unite_impacts) |clip| {
                        if (clip.id == spawn.animation) break clip;
                    } else unreachable;
                    var left = tick - spawn.at + 1;
                    var texture: ?u16 = null;
                    for (clip.frames) |entry| {
                        if (left < entry.ticks) {
                            texture = entry.entry;
                            break;
                        }
                        left -= entry.ticks;
                    }
                    if (texture == null) continue;
                    const birth = combat.party_strikes[case.actor].?.impact_births[i].?;
                    try std.testing.expectEqualDeep(spawn.position_q12, birth.position_q12);
                    try std.testing.expectEqualDeep(spawn.center, birth.center);
                    try std.testing.expectEqual(texture, frame.commands[count].texture);
                    try std.testing.expectEqual(battle.spell_scene.Blend.@"opaque", frame.commands[count].blend);
                    count += 1;
                }
                try std.testing.expectEqual(count, frame.count);
                try std.testing.expectEqual(count != 0, combat.hasSourceEffect());
                const white = tick >= timing.impact_tick + (if (case.actor == 2) @as(usize, 0) else 2) and tick < timing.impact_tick + (if (case.actor == 2) @as(usize, 19) else 6);
                const response = combat.spellReaction(combat.partyCount() + case.target);
                try std.testing.expectEqual(white, response != null);
                if (response) |sample| {
                    const expected = for (packet.value.physical_white_poses) |pose| {
                        if (std.mem.eql(u8, pose.id, combat.enemy(case.target).id)) break pose.entry;
                    } else unreachable;
                    try std.testing.expectEqual(expected, sample.entry.?);
                    const actor = battle.layout.actorLayout(combat, combat.partyCount() + case.target);
                    const entry = packet.value.entries[expected];
                    try std.testing.expectEqualDeep(battle.Rect{ .x = entry.x, .y = entry.y, .w = entry.w, .h = entry.h }, actor.sprite.rect);
                }
            }
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 30), checked);
}

test "Critical Double-Beat combinations keep both damage draws and bind the second camera to the moving target" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const b = try world_battle.load(allocator, world_battle.json);
    defer b.deinit();
    const c = try world_battle.load(allocator, world_battle.json_c);
    defer c.deinit();
    const ba = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer ba.deinit();
    const ca = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer ca.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    const Reference = struct { cases: []const struct { region: []const u8, actor: usize, target: usize, critical: bool, repeat_target: usize, repeat_focus_q12: [3]i32 } };
    const reference = try std.json.parseFromSlice(Reference, allocator, @embedFile("../fixtures/physical_impact_vectors.json"), .{ .ignore_unknown_fields = true });
    defer reference.deinit();
    var checked: usize = 0;
    for (reference.value.cases) |case| {
        if (case.actor != 0 or case.target != 0 or case.critical) continue;
        const data = if (std.mem.eql(u8, case.region, "b")) b.value else c.value;
        const art = if (std.mem.eql(u8, case.region, "b")) ba.value else ca.value;
        for (0..4) |mask| {
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
            sourceDoubleBeat(&combat, data, art, 0, 0);
            combat.roc_idle_at = 0;
            try combat.attachSpellScenes(&packet.value);
            const timing = combat.partyAttackTiming(0).?;
            const first = mask & 1 != 0;
            const second = mask & 2 != 0;
            const values = [_]u15{ 51, if (first) 0 else 51, 51, 51, if (second) 0 else 51, 51 };
            var draws = rules.Draws{ .values = &values };
            const amount = rules.physicalDamage(combat.stats(0).attack, combat.stats(6).defense, 51, false);
            for (1..timing.return_tick + timing.release_tick + 1) |tick| {
                try combat.tickReplay(.{}, &draws);
                const one: u16 = @intCast(if (tick >= timing.impact_tick) amount * @as(u32, if (first) 3 else 1) else 0);
                const two: u16 = @intCast(if (tick >= timing.return_tick + timing.impact_tick) amount * @as(u32, if (second) 3 else 1) else 0);
                try std.testing.expectEqual(@as(u16, 20000) - one - (if (case.repeat_target == 0) two else 0), combat.enemy_hp[0]);
                if (case.repeat_target != 0) try std.testing.expectEqual(@as(u16, 20000) - two, combat.enemy_hp[case.repeat_target]);
                if (tick == timing.return_tick and second) try std.testing.expectEqualDeep(case.repeat_focus_q12, combat.actor_camera.?.target[0]);
            }
            try std.testing.expectEqual(@as(usize, 6), draws.cursor);
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 8), checked);
}

test "Critical Killer threshold and lethal Pahn impacts preserve KO locks and rollback a birth" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const data = try world_battle.load(allocator, world_battle.json_c);
    defer data.deinit();
    const art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer art.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    for ([_]bool{ false, true }) |killer| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        sourceDoubleBeat(&combat, data.value, art.value, 0, 0);
        combat.runes[0] = if (killer) combat.content.systems.?.runeIndex("killer").? else null;
        try combat.attachSpellScenes(&packet.value);
        const values = [_]u15{ 51, 25 };
        var draws = rules.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(killer, combat.party_strikes[0].?.critical);
    }
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    sourceDoubleBeat(&combat, data.value, art.value, 2, 0);
    combat.runes[2] = null;
    combat.enemy_hp[0] = 1;
    try combat.attachSpellScenes(&packet.value);
    const timing = combat.partyAttackTiming(2).?;
    const launch = [_]u15{ 51, 0 };
    var draws = rules.Draws{ .values = &launch };
    for (1..timing.impact_tick) |_| try combat.tickReplay(.{}, &draws);
    const before = try stateBytes(combat);
    defer allocator.free(before);
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    const after = try stateBytes(combat);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expect(combat.party_strikes[2].?.impact_births[0] == null);
    const variance = [_]u15{51};
    draws = .{ .values = &variance };
    const down = timing.impact_tick + timing.target_release_delay;
    const cleanup = down + combat.enemy(0).knockout_ticks.? - 1;
    for (timing.impact_tick..cleanup + 1) |tick| {
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        try std.testing.expectEqual(tick >= down, combat.enemyInactive(0));
        try std.testing.expectEqual(tick < cleanup, combat.coordinatorLocked(6));
        if (tick < down) try std.testing.expect(battle.world_art.actorSample(art.value, &combat, 6).visible);
    }
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
}

test "simultaneous Buddha revival consumes first slots preserves ailments and retains queued turns" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.phase = .resolving;
    combat.round_menu_pending = true;
    combat.active = null;
    combat.coordinator = null;
    for (0..6) |actor| {
        const member = &combat.progress.party[actor];
        member.max_hp = 101;
        member.hp = 0;
        member.status = .poisoned;
        member.balloons = 2;
        member.inventory.slots[0] = .{ .id = .medicine, .uses = 6 };
        member.inventory.slots[1] = .{ .id = .sacrificial_buddha, .uses = 0 };
        member.inventory.slots[2] = .{ .id = .needle, .uses = 4 };
        member.inventory.slots[3] = .{ .id = .sacrificial_buddha, .uses = 0 };
        combat.asleep[actor] = 2;
        combat.unbalanced[actor] = 2;
        combat.accuracy_reduced[actor] = true;
        combat.rune_blocked[actor] = true;
        combat.actions[actor] = if (actor == 0) null else .defend;
        combat.markPartyKnockout(actor);
    }
    var draws = rules.Draws{ .values = &.{} };
    try combat.tickReplay(.{}, &draws);
    const birth = combat.camera_ticks;
    for (0..6) |actor| {
        try std.testing.expect(combat.revivals[actor] != null);
        try std.testing.expectEqual(field.items.Id.needle, combat.progress.party[actor].inventory.slots[1].?.id);
        try std.testing.expectEqual(field.items.Id.sacrificial_buddha, combat.progress.party[actor].inventory.slots[2].?.id);
    }
    for (1..124) |age| {
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(birth + age, combat.camera_ticks);
        try std.testing.expectEqual(battle.Phase.resolving, combat.phase);
        for (0..6) |actor| {
            try std.testing.expectEqual(@as(u16, if (age < 113) 0 else 50), combat.hp(actor));
            if (age < 113) {
                try std.testing.expect(combat.recentItemImpact(actor) == null);
            } else {
                const impact = combat.recentItemImpact(actor).?;
                try std.testing.expect(impact.revived);
                try std.testing.expectEqual(@as(u16, 50), impact.recovered_hp);
            }
            try std.testing.expectEqual(field.game_state.Status.poisoned, if (age < 113) combat.knockout_status[actor].? else combat.progress.party[actor].status);
            try std.testing.expectEqual(@as(u8, 2), combat.progress.party[actor].balloons);
            try std.testing.expectEqual(@as(u8, 2), combat.asleep[actor]);
            try std.testing.expectEqual(@as(u8, 2), combat.unbalanced[actor]);
            try std.testing.expect(combat.accuracy_reduced[actor] and combat.rune_blocked[actor]);
            try std.testing.expectEqual(actor == 0 and age >= 113, combat.acted[actor]);
            try std.testing.expectEqual(if (actor == 0) null else @as(?battle.Action, .defend), combat.actions[actor]);
            try std.testing.expectEqual(age < 123, combat.coordinatorLocked(actor));
            try std.testing.expectEqual(@as(usize, 3), combat.progress.party[actor].inventory.count());
        }
    }
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
}

test "Buddha protected failure retries the next whole slot and zero half HP commits ordinary KO" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    for ([_]u16{ 1, 101 }) |maximum| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.active = null;
        combat.phase = .resolving;
        combat.round_menu_pending = true;
        combat.progress.party[0].max_hp = maximum;
        combat.progress.party[0].hp = 0;
        combat.progress.party[0].status = .poisoned;
        combat.progress.party[0].balloons = 2;
        combat.progress.party[0].inventory = .{};
        combat.progress.party[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        combat.progress.party[0].inventory.slots[1] = .{ .id = .sacrificial_buddha, .uses = 0 };
        combat.protection[0] = 2;
        combat.advanceRevivals();
        try std.testing.expect(combat.revivals[0] == null);
        try std.testing.expectEqual(@as(usize, 2), combat.progress.party[0].inventory.count());
        combat.markPartyKnockout(0);
        var draws = rules.Draws{ .values = &.{} };
        try combat.tickReplay(.{}, &draws);
        for (1..124) |age| {
            try combat.tickReplay(.{}, &draws);
            if (age == 112) combat.protection[0] = 0;
            try std.testing.expectEqual(@as(u16, 0), combat.hp(0));
        }
        try std.testing.expectEqual(@as(usize, 0), combat.progress.party[0].inventory.count());
        try std.testing.expectEqual(@as(?u32, 0), combat.revivalAge(0));
        for (1..124) |age| {
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(@as(u16, if (age >= 113) maximum / 2 else 0), combat.hp(0));
        }
        try std.testing.expect(combat.revivals[0] == null);
        try std.testing.expect(!combat.knockout_pending[0]);
        try std.testing.expectEqual(@as(u8, if (maximum == 1) 0 else 2), combat.progress.party[0].balloons);
        try std.testing.expectEqual(if (maximum == 1) field.game_state.Status.unconscious else .poisoned, combat.progress.party[0].status);
        try std.testing.expect(combat.acted[0]);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    }
}

test "Legacy archer waits for pending front knockouts without target draws" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json_c);
    defer source.deinit();
    for ([_]bool{ false, true }) |active_effect| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        try sourceRoundBoundary(&combat, source.value);
        const owner = combat.partyCount();
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        for (combat.progress.party) |*member| {
            member.hp = 0;
            member.status = .unconscious;
        }
        combat.knockout_pending[0] = true;
        if (active_effect) combat.active = .{ .actor = 0, .target = 0, .kind = .defend };
        var draws = rules.Draws{ .values = &.{} };
        combat.replay_draws = &draws;
        try std.testing.expect(!combat.frontProjectileDecision(owner));
        try std.testing.expectEqual(if (active_effect) @as(?usize, null) else owner, combat.pending_enemy_actor);
        try std.testing.expect(!combat.acted[owner] and draws.cursor == 0);
        combat.active = null;
        combat.knockout_pending[0] = false;
        try std.testing.expect(combat.frontProjectileDecision(owner));
        try std.testing.expect(combat.acted[owner] and combat.pending_enemy_actor == null);
        try std.testing.expectEqual(.select, combat.coordinator.?.stage);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    }
}

test "Rabbit live and shared decisions agree on source projectile target boundaries" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    const effects = try battle_systems.enemy.load(allocator);
    defer effects.deinit();
    const policies = try @import("campaign_policies").enemy_policy.load(allocator);
    defer policies.deinit();
    const rabbit_encounter = for (source.value.encounters) |encounter| {
        if (encounter.enemies.len >= 2 and std.mem.eql(u8, encounter.enemies[0], "killer_rabbit")) break encounter;
    } else return error.MissingRabbitFixture;
    var encounters = [_]battle.Encounter{rabbit_encounter};
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.content.enemies = source.value.enemies;
    combat.content.encounters = &encounters;
    combat.content.protection = source.value.protection;
    combat.encounter = 0;
    combat.startEncounter();
    combat.phase = .resolving;
    const owner = combat.partyCount();
    var rows: [6]battle_systems.enemy.PartyRow = undefined;
    for (&rows, 0..) |*row, slot| row.* = .{ .slot = @intCast(slot), .front = combat.partyRow(slot) == .front, .active = true, .locked = false };
    for ([_]u15{ 0, 1, 327, 328, 16383, 16384, 16711, 17000, 32439, 32766, 32767 }) |roll| {
        combat.active = null;
        const values = [_]u15{ 20000, roll };
        var live = rules.Draws{ .values = &values };
        combat.replay_draws = &live;
        combat.rabbitDecision(owner);
        const expected = (@as(usize, roll) * 100 / 32767) % combat.partyCount();
        try std.testing.expect(combat.active.?.projectile and combat.active.?.target == expected);
        try std.testing.expect(combat.acted[owner] and combat.pending_enemy_actor == null);
        var planned = rules.Draws{ .values = &values };
        const outcome = try battle_systems.enemy.decide(&effects.value, &policies.value, "area_b.enemy.01", &rows, .{ .slot = 0, .front = true }, @intCast(combat.partyCount()), &planned);
        try std.testing.expect(outcome == .special and outcome.special.target_slot.? == expected);
        try std.testing.expectEqual(@as(usize, 2), live.cursor);
        try std.testing.expectEqual(live.cursor, planned.cursor);
    }
    combat.replay_draws = null;
}

test "Rabbit checks locked projectile and ordinary targets before drawing" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    const rabbit_encounter = for (source.value.encounters) |encounter| {
        if (encounter.enemies.len >= 2 and std.mem.eql(u8, encounter.enemies[0], "killer_rabbit")) break encounter;
    } else return error.MissingRabbitFixture;
    var encounters = [_]battle.Encounter{rabbit_encounter};
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.content.enemies = source.value.enemies;
    combat.content.encounters = &encounters;
    combat.content.protection = source.value.protection;
    combat.encounter = 0;
    combat.startEncounter();
    combat.active = null;
    combat.phase = .resolving;
    const owner = combat.partyCount();
    combat.front_projectiles[0] = .{ .actor = owner + 1, .target = 0 };
    // Projectile chooses locked Hero, then ordinary fallback skips Hero and selects Gremio.
    var draws = rules.Draws{ .values = &.{ 32767, 0, 32767, 0 } };
    combat.replay_draws = &draws;
    combat.rabbitDecision(owner);
    try std.testing.expect(combat.active.?.kind == .attack and !combat.active.?.projectile);
    try std.testing.expectEqual(@as(usize, 1), combat.active.?.target);
    try std.testing.expectEqual(@as(usize, 4), draws.cursor);
    try std.testing.expect(combat.pending_enemy_actor == null and combat.acted[owner]);
}

test "Rabbit retries locked and pending-knockout fronts without target draws" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    const rabbit_encounter = for (source.value.encounters) |encounter| {
        if (encounter.enemies.len >= 2 and std.mem.eql(u8, encounter.enemies[0], "killer_rabbit")) break encounter;
    } else return error.MissingRabbitFixture;
    var encounters = [_]battle.Encounter{rabbit_encounter};
    for ([_]enum { locked, pending_knockout, inactive }{ .locked, .pending_knockout, .inactive }) |case| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.content.enemies = source.value.enemies;
        combat.content.encounters = &encounters;
        combat.encounter = 0;
        combat.startEncounter();
        combat.active = null;
        combat.phase = .resolving;
        const owner = combat.partyCount();
        for (1..combat.partyCount()) |member| if (combat.partyRow(member) == .front) {
            combat.progress.party[member].hp = 0;
            combat.progress.party[member].status = .unconscious;
        };
        if (case != .locked) {
            combat.progress.party[0].hp = 0;
            combat.knockout_pending[0] = case == .pending_knockout;
            if (case == .inactive) combat.progress.party[0].status = .unconscious;
        } else {
            combat.front_projectiles[0] = .{ .actor = owner + 1, .target = 0 };
        }
        var draws = rules.Draws{ .values = &.{ 0, 32767, 0 } };
        combat.replay_draws = &draws;
        combat.rabbitDecision(owner);
        try std.testing.expect(combat.active == null);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        if (case == .inactive) {
            try std.testing.expect(combat.acted[owner] and combat.pending_enemy_actor == null);
            continue;
        }
        try std.testing.expect(!combat.acted[owner] and combat.pending_enemy_actor == owner);
        combat.front_projectiles[0] = null;
        combat.knockout_pending[0] = false;
        combat.progress.party[0].hp = 1;
        combat.replay_draws = null;
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.acted[owner] and combat.pending_enemy_actor == null);
        try std.testing.expect(combat.active.?.projectile and combat.active.?.target == 0);
        try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    }
}

test "Roc skips its turn when no living front target remains" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    const roc_encounter = for (source.value.encounters) |encounter| {
        if (encounter.enemies.len == 1 and std.mem.eql(u8, encounter.enemies[0], "roc")) break encounter;
    } else return error.MissingRocFixture;
    var encounters = [_]battle.Encounter{roc_encounter};
    for ([_]bool{ false, true }) |party_defeated| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.content.enemies = source.value.enemies;
        combat.content.encounters = &encounters;
        combat.content.protection = source.value.protection;
        combat.encounter = 0;
        combat.startEncounter();
        combat.active = null;
        combat.phase = .resolving;
        combat.acted = @splat(true);
        const owner = combat.partyCount();
        combat.acted[owner] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        for (0..combat.partyCount()) |member| if (combat.partyRow(member) == .front or party_defeated) {
            combat.progress.party[member].hp = 0;
            combat.progress.party[member].status = .unconscious;
        };
        var draws = rules.Draws{ .values = &.{} };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(.select, combat.coordinator.?.stage);
        try std.testing.expect(combat.acted[owner] and combat.coordinator.?.completed);
        try std.testing.expect(combat.pending_enemy_actor == null and combat.active == null);
        for (0..200) |_| {
            if (combat.phase != .resolving) break;
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(if (party_defeated) battle.Phase.defeat else .battle_menu, combat.phase);
        if (!party_defeated) try std.testing.expectEqual(battle.Row.front, combat.partyRow(3));
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    }
}

test "Roc retries a locked or RNG-rejected front target without another priority selection" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    const roc_encounter = for (source.value.encounters) |encounter| {
        if (encounter.enemies.len == 1 and std.mem.eql(u8, encounter.enemies[0], "roc")) break encounter;
    } else return error.MissingRocFixture;
    var encounters = [_]battle.Encounter{roc_encounter};
    for ([_]bool{ false, true }) |locked| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.content.enemies = source.value.enemies;
        combat.content.encounters = &encounters;
        combat.content.protection = source.value.protection;
        combat.encounter = 0;
        combat.startEncounter();
        combat.phase = .resolving;
        combat.acted = @splat(true);
        const owner = combat.partyCount();
        combat.acted[owner] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        for (1..combat.partyCount()) |member| {
            combat.progress.party[member].hp = 0;
            combat.progress.party[member].status = .unconscious;
        }
        combat.active = if (locked) .{ .actor = 0, .target = 0, .kind = .defend } else null;
        const values = [_]u15{ 50, 51, 0 };
        var draws = rules.Draws{ .values = if (locked) values[1..] else &values };
        combat.replay_draws = &draws;
        combat.rocDecision(owner);
        try std.testing.expectEqual(if (locked) @as(?usize, null) else owner, combat.pending_enemy_actor);
        try std.testing.expect(!combat.acted[owner] and combat.coordinator.?.stage == .dispatch);
        try std.testing.expectEqual(@as(usize, if (locked) 0 else 1), draws.cursor);
        combat.active = null;
        combat.rocDecision(owner);
        try std.testing.expect(combat.pending_enemy_actor == null and combat.acted[owner]);
        try std.testing.expect(combat.active.?.kind == .attack and combat.active.?.target == 0);
        try std.testing.expectEqual(@as(usize, if (locked) 2 else 3), draws.cursor);
    }
}

test "Roc waits while an active target reaction advances and then attacks" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    const roc_encounter = for (source.value.encounters) |encounter| {
        if (encounter.enemies.len == 1 and std.mem.eql(u8, encounter.enemies[0], "roc")) break encounter;
    } else return error.MissingRocFixture;
    var encounters = [_]battle.Encounter{roc_encounter};
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.content.enemies = source.value.enemies;
    combat.content.encounters = &encounters;
    combat.content.protection = source.value.protection;
    combat.encounter = 0;
    combat.startEncounter();
    combat.phase = .resolving;
    combat.acted = @splat(true);
    const owner = combat.partyCount();
    combat.acted[owner] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
    for (1..combat.partyCount()) |member| {
        combat.progress.party[member].hp = 0;
        combat.progress.party[member].status = .unconscious;
    }
    combat.active = .{ .actor = 0, .target = 0, .kind = .defend };
    var draws = rules.Draws{ .values = &.{ 51, 0 } };
    var waited: usize = 0;
    while (combat.active != null and combat.active.?.kind == .defend and waited < 100) : (waited += 1) {
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.pending_enemy_actor == null and !combat.acted[owner]);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    }
    try std.testing.expect(waited > 0 and combat.active == null);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.active.?.kind == .attack and combat.active.?.target == 0);
    try std.testing.expect(combat.acted[owner]);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
}

test "Roc waits for a front knockout to settle or revive before deciding its target" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    const roc_encounter = for (source.value.encounters) |encounter| {
        if (encounter.enemies.len == 1 and std.mem.eql(u8, encounter.enemies[0], "roc")) break encounter;
    } else return error.MissingRocFixture;
    var encounters = [_]battle.Encounter{roc_encounter};
    for ([_]bool{ false, true }) |revives| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.content.enemies = source.value.enemies;
        combat.content.encounters = &encounters;
        combat.content.protection = source.value.protection;
        combat.encounter = 0;
        combat.startEncounter();
        combat.active = null;
        combat.phase = .resolving;
        combat.acted = @splat(true);
        const owner = combat.partyCount();
        combat.acted[owner] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        for (0..combat.partyCount()) |member| if (member != 3) {
            combat.progress.party[member].hp = 0;
            combat.progress.party[member].status = .unconscious;
        };
        combat.progress.party[0].inventory = .{};
        if (revives) combat.progress.party[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        combat.markPartyKnockout(0);
        var draws = rules.Draws{ .values = &.{ 51, 0 } };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(!combat.acted[owner] and combat.pending_enemy_actor == owner);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        if (revives) {
            try std.testing.expect(combat.revivals[0] != null);
            var waited: usize = 0;
            while (combat.revivals[0] != null and waited < 150) : (waited += 1) {
                try combat.tickReplay(.{}, &draws);
                try std.testing.expect(!combat.acted[owner] and combat.active == null);
                try std.testing.expectEqual(@as(usize, 0), draws.cursor);
            }
            try std.testing.expect(combat.revivals[0] == null and combat.hp(0) > 0);
            try combat.tickReplay(.{}, &draws);
            try std.testing.expect(combat.active.?.kind == .attack and combat.active.?.target == 0);
            try std.testing.expectEqual(@as(usize, 2), draws.cursor);
        } else {
            try combat.tickReplay(.{}, &draws);
            try std.testing.expect(combat.acted[owner] and combat.pending_enemy_actor == null);
            try std.testing.expectEqual(.select, combat.coordinator.?.stage);
            try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        }
    }
}

test "Buddha waits for lethal Roc hurt and holds the ward through protector revival" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.content.enemies = source.value.enemies;
    const roc_encounter = for (source.value.encounters) |encounter| {
        if (encounter.enemies.len == 1 and std.mem.eql(u8, encounter.enemies[0], "roc")) break encounter;
    } else return error.MissingRocFixture;
    var encounters = [_]battle.Encounter{roc_encounter};
    combat.content.encounters = &encounters;
    combat.content.protection = source.value.protection;
    combat.encounter = 0;
    combat.enemy_hp[0] = combat.enemy(0).max_hp;
    const timing = combat.enemy(0).ordinary_timing.?;
    combat.phase = .resolving;
    combat.active = .{ .actor = 6, .target = 0, .protector = 1, .kind = .attack, .damage_at_impact = true };
    combat.coordinator = .{ .stage = .select, .current_actor = 6, .completed = true, .remaining = 10000 };
    combat.action_ticks = timing.impact_tick - 1;
    combat.coordinator.?.elapsed = combat.action_ticks;
    combat.progress.party[1].hp = 1;
    combat.progress.party[1].max_hp = 101;
    combat.progress.party[1].status = .poisoned;
    combat.progress.party[1].balloons = 2;
    combat.progress.party[1].inventory = .{};
    combat.progress.party[1].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
    combat.actions[1] = .defend;
    const ward_hp = combat.hp(0);
    const release = combat.protectorReleaseTick(combat.active.?);
    var draws = rules.Draws{ .values = &.{100} };
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(u16, 0), combat.hp(1));
    try std.testing.expect(combat.revivals[1] == null);
    while (combat.effectTicks() < release) {
        try std.testing.expectEqual(@as(usize, 1), combat.progress.party[1].inventory.count());
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expect(combat.revivals[1] != null);
    try std.testing.expectEqual(@as(usize, 0), combat.progress.party[1].inventory.count());
    try std.testing.expect(!combat.active.?.protector_down);
    const ward_start = release + 123 + 1;
    try std.testing.expectEqual(ward_start, combat.wardReturnTick(combat.active.?));
    while (combat.effectTicks() < ward_start) {
        try std.testing.expect(!combat.active.?.ward_returning);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expect(combat.active.?.ward_returning);
    try std.testing.expectEqual(@as(u16, 50), combat.hp(1));
    try std.testing.expectEqual(ward_hp, combat.hp(0));
    try std.testing.expectEqual(field.game_state.Status.poisoned, combat.progress.party[1].status);
    try std.testing.expectEqual(@as(u8, 2), combat.progress.party[1].balloons);
    try std.testing.expect(!combat.acted[1]);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
}

test "Buddha composes twenty-four down-pose clones on the source plane and restores white" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/world_b_party_art.json", allocator, .limited(512 * 1024));
    defer allocator.free(bytes);
    const art = try battle.world_art.load(allocator, bytes);
    defer art.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.content.world_art = art.value;
    combat.active = null;
    var origins: [6]battle.Position = undefined;
    for (0..6) |actor| {
        combat.progress.party[actor].hp = 0;
        combat.progress.party[actor].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        combat.markPartyKnockout(actor);
        try std.testing.expect(!combat.commitPartyKnockout(actor));
        origins[actor] = combat.revivals[actor].?.origin;
    }
    const spec = fixture.items.value.automatic_revival.?;
    var moved = art.value;
    moved.formation_slots[0].x += 100;
    for (1..124) |age| {
        combat.camera_ticks = @intCast(age);
        combat.advanceRevivals();
        const frame = battle.world_art.compose(moved, combat);
        var clones: usize = 0;
        for (frame.quads[0..frame.length]) |quad| {
            if (quad.medicine_particle) {
                clones += 1;
                try std.testing.expectEqualDeep([3]u8{ 128, 0, 0 }, quad.light);
                try std.testing.expectEqual(@as(f32, 0), quad.position.z);
                const row = spec.particles[@min(age - 18, spec.particles.len - 1)];
                var matched = false;
                for (0..6) |actor| for (row) |offset| {
                    if (@abs(quad.position.x - origins[actor].x - offset[0]) < 0.001 and @abs(quad.position.y - origins[actor].y - offset[1]) < 0.001) {
                        try std.testing.expectEqualDeep(moved.actors[actor].poses[moved.actors[actor].animations[3][0].pose], quad.sprite);
                        matched = true;
                    }
                };
                try std.testing.expect(matched);
            } else if (quad.actor) |actor| if (actor < 6 and age < 123) {
                try std.testing.expectEqualDeep(origins[actor], quad.position);
                const light: u8 = if (age >= 78 and age < 109) @intCast(255 - 4 * (age - 78)) else 128;
                try std.testing.expectEqualDeep([3]u8{ light, light, light }, quad.light);
                if (age < 113) try std.testing.expectEqualDeep(moved.actors[actor].poses[moved.actors[actor].animations[3][0].pose], quad.sprite);
            };
        }
        try std.testing.expectEqual(@as(usize, if (age >= 18 and age < 110) 24 else 0), clones);
    }
}

test "Buddha holds ordinary defeat and round boundary poison is applied only once" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const host = try hostFixture();
    defer host.deinit();
    const source = try world_battle.load(allocator, world_battle.json_c);
    defer source.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    try sourceRoundBoundary(&combat, source.value);
    combat.progress.party[0].max_hp = 101;
    combat.progress.party[0].hp = 1;
    combat.progress.party[0].status = .poisoned;
    combat.progress.party[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
    combat.unbalanced[0] = 2;
    var draws = rules.Draws{ .values = &.{100} };
    try combat.tickReplay(.{}, &draws);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.round_menu_pending);
    try std.testing.expectEqual(@as(u32, 2), combat.round);
    try std.testing.expectEqual(@as(u8, 1), combat.unbalanced[0]);
    try std.testing.expectEqual(@as(u16, 0), combat.hp(0));
    for (0..124) |_| try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
    try std.testing.expectEqual(@as(u16, 50), combat.hp(0));
    try std.testing.expectEqual(field.game_state.Status.poisoned, combat.progress.party[0].status);
    try std.testing.expectEqual(@as(u8, 1), combat.unbalanced[0]);
    try std.testing.expectEqual(@as(u32, 2), combat.round);

    combat.integration = null;
    combat.phase = .resolving;
    combat.round_menu_pending = false;
    combat.coordinator = .{ .stage = .round_ready, .current_actor = 0 };
    for (0..6) |actor| {
        combat.progress.party[actor].hp = 0;
        combat.progress.party[actor].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        combat.markPartyKnockout(actor);
    }
    var empty = rules.Draws{ .values = &.{} };
    for (0..124) |_| {
        try combat.tickReplay(.{}, &empty);
        try std.testing.expectEqual(battle.Phase.resolving, combat.phase);
    }
    for (0..6) |actor| try std.testing.expectEqual(combat.progress.party[actor].max_hp / 2, combat.hp(actor));
    try std.testing.expect(!combat.hasPendingRevival());
    try std.testing.expectEqual(@as(usize, 0), empty.cursor);
}

test "Buddha inventory and ownership roll back when another scheduler draw fails" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.phase = .resolving;
    combat.active = null;
    combat.coordinator = .{ .stage = .select, .current_actor = 0 };
    combat.progress.party[0].hp = 0;
    combat.progress.party[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
    combat.markPartyKnockout(0);
    const before = try stateBytes(combat);
    defer allocator.free(before);
    var empty = rules.Draws{ .values = &.{} };
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &empty));
    const after = try stateBytes(combat);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(usize, 0), empty.cursor);
}

test "Buddha generic atlas clips and clones share source clocks independent of bearer scale" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.phase = .resolving;
    combat.round_menu_pending = true;
    combat.active = null;
    combat.coordinator = null;
    for (0..6) |actor| {
        combat.progress.party[actor].hp = 0;
        combat.progress.party[actor].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        combat.markPartyKnockout(actor);
    }
    var draws = rules.Draws{ .values = &.{} };
    try combat.tickReplay(.{}, &draws);
    const spec = combat.rules.automatic_revival.?;
    const origin = combat.revivals[0].?.origin;
    combat.content.formation_slots[0].x += 100;
    combat.actor_sizes[0] = 8192;
    for (1..124) |age| {
        try combat.tickReplay(.{}, &draws);
        var clones: usize = 0;
        for (0..6) |actor| {
            if (age < 123) {
                const art = combat.partyProfile(actor).revival_art.?;
                const body = battle.layout.actorLayout(combat, actor);
                const expected = if (age < 113) art.down.sample(@intCast(age)) else art.recovery.sample(@intCast(age - 113));
                try std.testing.expectEqualDeep(expected, body.sprite);
            }
            const quads = battle.layout.revivalParticles(combat, actor);
            try std.testing.expectEqual(age >= 18 and age < 110, quads != null);
            if (quads) |values| {
                const row = spec.particles[@min(age - 18, spec.particles.len - 1)];
                for (values, row) |quad, offset| {
                    const captured = combat.revivals[actor].?.origin;
                    try std.testing.expectEqualDeep(combat.partyProfile(actor).revival_art.?.down.frames[0].pose, quad.sprite);
                    try std.testing.expectApproxEqAbs(captured.x + offset[0], quad.position.x, 0.001);
                    try std.testing.expectApproxEqAbs(captured.y + offset[1], quad.position.y, 0.001);
                    try std.testing.expectEqual(@as(f32, 0), quad.position.z);
                    try std.testing.expectEqualDeep([3]u8{ 128, 0, 0 }, quad.light);
                    const scale = battle.layout.actorLayout(combat, 1).scale;
                    try std.testing.expectApproxEqAbs(scale, quad.scale, 0.001);
                    clones += 1;
                }
            }
            const light: u8 = if (age >= 78 and age < 109) @intCast(255 - 4 * (age - 78)) else 128;
            try std.testing.expectEqual(light, battle.revival.revivalLight(combat, actor));
        }
        if (age < 123) try std.testing.expectEqualDeep(origin, battle.layout.worldPosition(&combat, 0));
        try std.testing.expectEqual(@as(usize, if (age >= 18 and age < 110) 24 else 0), clones);
    }
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "Buddha generic art admits every exported actor without a Unite script owner" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try battle.load(allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 44), parsed.value.party.len);
    for (parsed.value.party) |profile| {
        var content = parsed.value;
        var initial = [_][]const u8{profile.id};
        content.initial_party = &initial;
        content.party_positions = content.party_positions[0..1];
        var members: [1]battle.Member = undefined;
        var combat = try battle.State.init(content, fixture.items.value, &members, 17);
        combat.progress.party[0].hp = 0;
        combat.progress.party[0].inventory = .{};
        combat.progress.party[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        combat.markPartyKnockout(0);
        try std.testing.expect(!combat.commitPartyKnockout(0));
        for (1..124) |age| {
            combat.camera_ticks = @intCast(age);
            combat.advanceRevivals();
            if (age == 18) {
                const quads = battle.layout.revivalParticles(combat, 0).?;
                for (quads) |quad| try std.testing.expectEqualDeep(profile.revival_art.?.down.frames[0].pose, quad.sprite);
            }
            if (age == 113) {
                const body = battle.layout.actorLayout(combat, 0);
                try std.testing.expectEqualDeep(profile.revival_art.?.recovery.frames[0].pose, body.sprite);
            }
        }
        try std.testing.expectEqual(profile.max_hp / 2, combat.hp(0));
        try std.testing.expect(!combat.hasPendingRevival());
        combat.progress.party[0].hp = 0;
        combat.progress.party[0].status = .unconscious;
        const down = battle.layout.actorLayout(combat, 0);
        try std.testing.expectEqualDeep(profile.revival_art.?.down.frames[0].pose, down.sprite);
    }
}

test "host binds the reviewed spell, unite and outcome catalogues and the character ids" {
    const host = try hostFixture();
    defer host.deinit();
    try std.testing.expectEqual(@as(?u8, 8), host.characterId("Hero"));
    try std.testing.expectEqual(@as(?u8, 38), host.characterId("yam_koo"));
    try std.testing.expectEqual(@as(?u8, 32), host.characterId("Tai Ho"));
    try std.testing.expectEqual(@as(?u8, null), host.characterId("not a character"));
    try std.testing.expectEqual(@as(usize, 33), host.spellRules().spells.len);
    try std.testing.expect(host.spellIndexForName("Flaming Arrows") != null);
    try std.testing.expect(host.spellIndexForName("No Such Spell") == null);
    try std.testing.expect(host.uniteCatalogue().count() == 32);
    try std.testing.expect(host.uniteCatalogue().blockedCount() == 0);
    try std.testing.expectEqual(@as(?u8, 9), host.runeByte(7));
    try std.testing.expectEqual(@as(?u8, 33), host.runeByte(20));
}

test "scripted outcome commits exactly once and preserves its owner across a snapshot" {
    const host = try hostFixture();
    defer host.deinit();
    const asset = host.outcomeAsset();
    const battle_contract = outcomes_mod.battleById(asset, "va2-s0-e11") orelse return error.MissingBattle;
    var scripted = try host_mod.ScriptedOutcome.begin(asset, battle_contract.id, 7);
    const consequence = try scripted.resolve(.{ .live_enemies = 0, .end_flag = false, .defeat_flag = false });
    try std.testing.expectEqual(outcomes_mod.Branch.victory, consequence.branch);
    const captured = scripted.capture();
    const another = outcomes_mod.battleById(asset, "va2-s5-e7") orelse return error.MissingBattle;
    try std.testing.expectError(error.BattleMismatch, host_mod.resumeScripted(asset, another.id, captured));
    var other = host_mod.ScriptedOutcome{ .host = .{}, .battle = another };
    try std.testing.expectError(error.BattleMismatch, other.restore(captured));
    try std.testing.expectError(error.BattleMismatch, other.adopt(captured, captured.token));
    try std.testing.expectEqual(outcomes_mod.Phase.idle, other.host.phase);
    var malformed = captured;
    malformed.battle_len = 255;
    try std.testing.expectError(error.InvalidSnapshot, host_mod.resumeScripted(asset, battle_contract.id, malformed));
    var resumed = try host_mod.resumeScripted(asset, battle_contract.id, captured);
    const receipt = try resumed.commit();
    try std.testing.expectEqualStrings(battle_contract.id, receipt.id());
    try std.testing.expectEqual(@as(u32, 1), receipt.sequence);
    try std.testing.expectError(error.AlreadyCommitted, resumed.commit());
    var foreign = try host_mod.ScriptedOutcome.begin(asset, battle_contract.id, 8);
    try std.testing.expectError(error.OwnershipMismatch, foreign.adopt(captured, 8));
    var pending = try host_mod.ScriptedOutcome.begin(asset, battle_contract.id, 9);
    _ = try pending.resolve(.{ .live_enemies = 1, .end_flag = false, .defeat_flag = false });
    try std.testing.expectError(error.ResultPending, pending.commit());
}

test "an ordinary round still rewards and returns through the integrated state" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
    combat.integration = .{ .host = host };
    var tape = Tape{};
    var draws = tape.init();
    try queueRound(&combat, .ordinary);
    try combat.tickReplay(.{ .confirm = true }, &draws);
    try tickToVictory(&combat, &draws, 2000);
    try std.testing.expectEqual(field.game_state.Status.healthy, combat.progress.party[0].status);
    try std.testing.expect(combat.reward_received > 0);
}

test "spell impact follows the reviewed spell plan with one atomic charge spend" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
    combat.integration = .{ .host = host };
    var tape = Tape{};
    var draws = tape.init();
    const before = combat.progress.party[0].rune_charges[0];
    try std.testing.expect(before > 0);
    try queueRound(&combat, .spell);
    try combat.tickReplay(.{ .confirm = true }, &draws);
    var ticks: usize = 0;
    while (combat.enemy_hp[0] == 5000 and ticks < 500) : (ticks += 1) try combat.tickReplay(.{}, &draws);
    try std.testing.expect(ticks < 500);
    // Flaming Arrows: power 100 + magic/2 (hero 65 -> 32), doubled by BonBon's
    // fire weakness.  The C bridge commits HP and the tier charge together.
    try std.testing.expectEqual(@as(u16, 5000 - 264), combat.enemy_hp[0]);
    try std.testing.expectEqual(before - 1, combat.progress.party[0].rune_charges[0]);
}

test "integrated Drops cures live ailments even at full HP and preserves protection" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const system = fixture.view.systems.?;
    var spell_index: usize = 0;
    for (system.spells, 0..) |spell, i| if (std.mem.eql(u8, spell.name, "Drops of Kindness")) {
        spell_index = i;
    };
    for ([_]bool{ false, true }) |protected| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        var draws = rules.Draws{};
        combat.replay_draws = &draws;
        combat.runes[0] = system.runeIndex("water");
        combat.progress.party[0].rune_charges = .{ 9, 9, 9, 9 };
        const target: usize = 1;
        combat.progress.party[target].status = .poisoned;
        combat.progress.party[target].balloons = 2;
        combat.accuracy_reduced[target] = true;
        combat.rune_blocked[target] = true;
        combat.asleep[target] = 1;
        combat.unbalanced[target] = 1;
        combat.protection[target] = if (protected) 2 else 0;
        const hp = combat.hp(target);
        var effect = battle.Effect{ .actor = 0, .target = target, .kind = .cast, .spell = spell_index };
        combat.applySpell(&effect);
        try std.testing.expectEqual(.cast, effect.kind);
        try std.testing.expectEqual(hp, combat.hp(target));
        try std.testing.expectEqual(.healthy, combat.progress.party[target].status);
        try std.testing.expectEqual(@as(u8, 0), combat.progress.party[target].balloons);
        try std.testing.expect(!combat.accuracy_reduced[target]);
        try std.testing.expect(!combat.rune_blocked[target]);
        try std.testing.expectEqual(@as(u8, 0), combat.asleep[target]);
        try std.testing.expectEqual(@as(u8, 1), combat.unbalanced[target]);
        try std.testing.expectEqual(@as(u8, if (protected) 2 else 0), combat.protection[target]);
        try std.testing.expectEqual(@as(u16, 8), combat.progress.party[0].rune_charges[0]);
    }
}

test "integrated spell adapter transfers resistance and immunity or refuses unknown required facts" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var system = fixture.view.systems.?;
    const spells = try allocator.alloc(rules.Spell, system.spells.len);
    defer allocator.free(spells);
    @memcpy(spells[0..system.spells.len], system.spells);
    const runes = try allocator.dupe(rules.Rune, system.runes);
    defer allocator.free(runes);
    const spell_index = system.spells.len - 1;
    system.spells = spells;
    system.runes = runes;
    fixture.view.systems = system;
    for (runes) |*rune| for (&rune.spells, &rune.spell_names) |*slot, *name| {
        if (slot.* == spell_index) {
            slot.* = null;
            name.* = "-";
        }
    };
    runes[0].spells[0] = spell_index;
    const Case = struct { name: []const u8, affinity: ?rules.Affinity = null, immune: ?bool = null, expected_hp: ?u16 };
    const cases = [_]Case{
        .{ .name = "Scolding", .affinity = .resistant, .expected_hp = 4949 },
        .{ .name = "Scolding", .affinity = .immune, .expected_hp = 5000 },
        .{ .name = "Scolding", .expected_hp = null },
        .{ .name = "Deadly Fingertips", .immune = true, .expected_hp = 5000 },
        .{ .name = "Deadly Fingertips", .immune = false, .expected_hp = 0 },
        .{ .name = "Deadly Fingertips", .expected_hp = null },
        .{ .name = "Voice of Earth", .expected_hp = null },
    };
    for (cases) |case| {
        spells[spell_index] = .{ .id = "adapter_spell", .name = case.name, .kind = .damage, .allies = false, .group = false, .power = 70, .field_use = false };
        runes[0].spell_names[0] = case.name;
        for (fixture.profiles.?) |*profile| {
            profile.other_affinity = case.affinity;
            profile.death_immune = case.immune;
            profile.airborne = null;
        }
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        var draws = rules.Draws{};
        combat.replay_draws = &draws;
        combat.runes[0] = 0;
        combat.progress.party[0].rune_charges = .{ 9, 9, 9, 9 };
        var effect = battle.Effect{ .actor = 0, .target = combat.partyCount(), .kind = .cast, .spell = spell_index };
        combat.applySpell(&effect);
        try std.testing.expectEqual(case.expected_hp orelse 5000, combat.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, if (case.expected_hp == null) 9 else 8), combat.progress.party[0].rune_charges[0]);
        try std.testing.expectEqual(case.expected_hp == null, effect.kind == .unavailable);
    }
}

test "physical rune techniques use the technique numerator and spend no charge" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();

    const Case = struct {
        rune: usize,
        amount: u32,
        charges: [4]u16,
    };
    var cases: [2]Case = undefined;
    for (&cases, [_]usize{ 7, 10 }) |*entry, rune_index| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
        combat.integration = .{ .host = host };
        // Pahn is the third owned member in the fixture.
        combat.runes[2] = rune_index;
        entry.charges = combat.progress.party[2].rune_charges;
        var tape = Tape{};
        var draws = tape.init();
        try queueRound(&combat, .rune);
        try combat.tickReplay(.{ .confirm = true }, &draws);
        var ticks: usize = 0;
        while (combat.enemy_hp[0] == 5000 and ticks < 500) : (ticks += 1) try combat.tickReplay(.{}, &draws);
        entry.amount = 5000 - combat.enemy_hp[0];
        try std.testing.expectEqual(entry.charges, combat.progress.party[2].rune_charges);
    }
    // Shrike stores numerator 20/10, Trick 15/10, over the same base draw tape:
    // 3 * shrike == 4 * trick, allowing the source truncation of at most 4.
    const shrike: i64 = cases[0].amount;
    const trick: i64 = cases[1].amount;
    try std.testing.expect(@abs(shrike * 3 - trick * 4) <= 4);
    try std.testing.expect(shrike > 0 and trick > 0);

    // Hate's auxiliary actor family is a typed refusal, not an ordinary strike.
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
    combat.integration = .{ .host = host };
    combat.runes[2] = 9; // Hate Rune catalogue index -> source byte 11
    try std.testing.expect(!combat.canPhysicalRune(2));
}

test "queued physical rune retargets a defeated enemy and skips an empty formation" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    combat.encounter = 1;
    combat.startEncounter();
    combat.runes[2] = 7; // Shrike Rune, source byte 9.
    combat.enemy_hp[0] = 0;
    combat.enemy_hp[1] = 5000;
    combat.enemy_hp[2] = 5000;
    const charges = combat.progress.party[2].rune_charges;
    try std.testing.expect(combat.canPhysicalRune(2));
    try std.testing.expect(combat.beginRuneAttack(2, 0));
    try std.testing.expectEqual(combat.partyCount() + 1, combat.active.?.target);
    try std.testing.expectEqual(@as(?usize, combat.partyCount()), combat.active.?.retargeted_from);
    try std.testing.expectEqual(charges, combat.progress.party[2].rune_charges);
    const damage = combat.active.?.amount;
    combat.phase = .resolving;
    var tape = Tape{};
    var draws = tape.init();
    for (0..500) |_| {
        if (combat.enemy_hp[1] < 5000) break;
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, @intCast(5000 - damage)), combat.enemy_hp[1]);

    combat.active = null;
    combat.enemy_hp = @splat(0);
    try std.testing.expect(!combat.beginRuneAttack(2, 0));
    combat.phase = .resolving;
    combat.actions = @splat(.defend);
    combat.actions[2] = .{ .rune_attack = 0 };
    combat.acted = @splat(true);
    combat.acted[2] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 2 };
    combat.active = .{ .actor = 0, .target = combat.partyCount(), .kind = .attack };
    const before = combat.coordinator.?;
    combat.advanceCoordinator();
    try std.testing.expectEqualDeep(before, combat.coordinator.?);
    try std.testing.expect(!combat.acted[2]);
    combat.active = null;
    combat.advanceCoordinator();
    try std.testing.expect(combat.acted[2] and combat.coordinator.?.completed);
    try std.testing.expectEqual(.select, combat.coordinator.?.stage);
    try std.testing.expectEqual(charges, combat.progress.party[2].rune_charges);
    try tickToVictory(&combat, &draws, 300);
}

test "queued spells reject invalid spell indices and target slots before effects start" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.phase = .resolving;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
    combat.actor_camera = try @TypeOf(combat.actor_camera.?).init(battle.layout.currentCamera(combat));
    for ([_]struct { rune: usize, spell: usize, invalid_target: usize }{
        .{ .rune = 0, .spell = 0, .invalid_target = combat.enemyCount() },
        .{ .rune = 0, .spell = 0, .invalid_target = std.math.maxInt(usize) },
        .{ .rune = 1, .spell = 2, .invalid_target = combat.partyCount() },
        .{ .rune = 0, .spell = std.math.maxInt(usize), .invalid_target = 0 },
    }) |case| {
        combat.runes[0] = case.rune;
        combat.progress.party[0].rune_charges[0] = 1;
        if (case.spell != std.math.maxInt(usize)) try std.testing.expect(combat.canCast(0, case.spell));
        const command = battle.Action{ .spell = .{ .index = case.spell, .target = case.invalid_target } };
        combat.actions[0] = command;
        const before = combat;
        const before_members = members;
        try std.testing.expect(!combat.beginSpellAction(0, command.spell));
        try std.testing.expectEqualDeep(before, combat);
        var draws = rules.Draws{ .values = &.{} };
        try std.testing.expectError(error.UnsupportedCoordinatorAction, combat.tickReplay(.{}, &draws));
        try std.testing.expectEqualDeep(before, combat);
        try std.testing.expectEqualDeep(before_members, members);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    }
}

test "queued offensive spells skip empty enemies without blocking ally spells" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    for ([_]struct { rune: usize, spell: usize, allies: bool }{
        .{ .rune = 0, .spell = 0, .allies = false },
        .{ .rune = 0, .spell = 1, .allies = false },
        .{ .rune = 1, .spell = 2, .allies = true },
        .{ .rune = 1, .spell = 3, .allies = true },
    }) |case| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        combat.runes[0] = case.rune;
        combat.base_stats[0].magic = 200;
        combat.refillMagic(0);
        try std.testing.expect(combat.canCast(0, case.spell));
        combat.enemy_hp = @splat(0);
        combat.phase = .resolving;
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = case.spell, .target = 0 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
        const charges = members[0].rune_charges;
        const random = combat.random;
        combat.advanceCoordinator();
        try std.testing.expectEqualDeep(charges, members[0].rune_charges);
        if (case.allies) {
            try std.testing.expect(combat.active != null and combat.active.?.kind == .cast);
        } else {
            try std.testing.expect(combat.active == null and combat.acted[0] and combat.coordinator.?.completed);
            try std.testing.expectEqualDeep(random, combat.random);
            var tape = Tape{};
            var draws = tape.init();
            try tickToVictory(&combat, &draws, 300);
        }
    }
}

test "queued Unite with no enemies releases the reservation and reaches victory" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    combat.unite_flags[1] = 0x100;
    combat.unite_flags[2] = 0x200;
    try queueRound(&combat, .unite);
    const leader: usize = 1;
    const boundary = combat.uniteBoundaryFor(leader) orelse return error.MissingUniteBoundary;
    var partner: ?usize = null;
    for (boundary.participantsSlice()) |participant| if (participant != leader) {
        partner = participant;
    };
    const assistant = partner orelse return error.MissingUniteParticipant;
    combat.enemy_hp = @splat(0);
    const before = combat.acted;
    try std.testing.expect(!combat.beginUniteAction(leader, 0));
    try std.testing.expectEqualDeep(before, combat.acted);
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.acted[leader] = false;
    combat.acted[assistant] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = leader };
    combat.active = .{ .actor = 0, .target = 0, .kind = .defend };
    combat.advanceCoordinator();
    try std.testing.expect(!combat.acted[leader] and combat.uniteBoundaryFor(leader) != null);
    combat.active = .{ .actor = 0, .target = combat.partyCount(), .kind = .attack };
    combat.advanceCoordinator();
    try std.testing.expect(!combat.acted[leader] and combat.uniteBoundaryFor(leader) != null);
    combat.active = null;
    const random = combat.random;
    combat.advanceCoordinator();
    try std.testing.expect(combat.acted[leader] and !combat.acted[assistant]);
    try std.testing.expect(combat.uniteBoundaryFor(leader) == null);
    try std.testing.expectEqual(@as(u16, 0x100), combat.unite_flags[leader]);
    try std.testing.expectEqual(@as(u16, 0x200), combat.unite_flags[assistant]);
    try std.testing.expectEqualDeep(random, combat.random);
    const choice = combat.coordinatorChoice();
    try std.testing.expect(choice == .actor and choice.actor == assistant);
    var tape = Tape{};
    var draws = tape.init();
    try tickToVictory(&combat, &draws, 500);
    try std.testing.expect(combat.acted[assistant]);
    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[leader]);
    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[assistant]);
}

test "queued Unite retargets presentation and damage after a knockout reaction releases" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.encounter = 1;
    combat.startEncounter();
    combat.integration = .{ .host = host };
    try combat.attachSpellScenes(&effects.value);
    try queueRound(&combat, .unite);
    const owner: usize = 1;
    const original = combat.partyCount();
    try std.testing.expectEqual(@import("battle_systems").unite.Target{ .enemy = 0 }, combat.uniteBoundaryFor(owner).?.target);

    combat.enemy_hp[0] = 0;
    combat.enemy_hp[1] = 1;
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.acted[owner] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
    combat.active = .{ .actor = 0, .target = original, .kind = .attack };
    const coordinator = combat.coordinator;
    combat.advanceCoordinator();
    try std.testing.expectEqualDeep(coordinator, combat.coordinator);
    try std.testing.expectEqual(@import("battle_systems").unite.Target{ .enemy = 0 }, combat.uniteBoundaryFor(owner).?.target);
    combat.active = null;

    var tape = Tape{};
    var draws = tape.init();
    try combat.tickReplay(.{}, &draws);
    const replacement = original + 1;
    try std.testing.expectEqual(replacement, combat.active.?.target);
    try std.testing.expectEqual(@as(?usize, original), combat.active.?.retargeted_from);
    try std.testing.expectEqual(@import("battle_systems").unite.Target{ .enemy = 1 }, combat.uniteBoundaryFor(owner).?.target);
    try std.testing.expectEqual(@as(i8, @intCast(replacement + 1)), combat.last_targets[owner]);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    for (0..500) |_| {
        if (combat.uniteBoundaryFor(owner) == null) break;
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expect(combat.uniteBoundaryFor(owner) == null);
    try std.testing.expectEqualSlices(u16, &.{ 0, 0, 5000 }, combat.enemy_hp[0..3]);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    const knockout = combat.unite_reactions[replacement] orelse return error.MissingUniteKnockout;
    try std.testing.expect(knockout.knockout_ticks > 0);
    combat.active = .{ .actor = owner, .target = replacement, .kind = .unite };
    combat.camera_ticks = knockout.started_at + knockout.knockout_ticks - 1;
    try std.testing.expect(combat.coordinatorLocked(replacement));
    combat.camera_ticks += 1;
    combat.advanceUniteReactionEvents();
    try std.testing.expect(!combat.coordinatorLocked(replacement));
    try std.testing.expect(!combat.spellReaction(replacement).?.visible);
}

test "four-member Unite skips each remaining participant when enemies are gone" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/blacksmith_battle.json"));
    defer content.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content.value, items.value, &members, 17);
    combat.integration = .{ .host = host };
    combat.choose(0);
    try std.testing.expect(combat.selectUnite(0, 5));
    combat.queue(.{ .unite = 0 });
    const boundary = combat.uniteBoundaryFor(0) orelse return error.MissingUniteBoundary;
    try std.testing.expectEqual(@as(u8, 4), boundary.count);
    var participants: [4]usize = undefined;
    @memcpy(&participants, boundary.participantsSlice());
    combat.enemy_hp = @splat(0);
    combat.phase = .resolving;
    combat.acted = @splat(true);
    for (participants) |participant| combat.acted[participant] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
    combat.advanceCoordinator();
    try std.testing.expect(combat.acted[0] and combat.uniteBoundaryFor(0) == null);
    for (0..3) |_| {
        const choice = combat.coordinatorChoice();
        try std.testing.expect(choice == .actor and choice.actor != 0);
        const member = choice.actor;
        try std.testing.expect(!combat.acted[member] and combat.actions[member].? == .assist);
        combat.coordinator.?.stage = .dispatch;
        combat.coordinator.?.current_actor = member;
        combat.advanceCoordinator();
        try std.testing.expect(combat.acted[member]);
    }
    for (participants) |participant| {
        try std.testing.expect(combat.acted[participant]);
        try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[participant]);
    }
    var tape = Tape{};
    var draws = tape.init();
    try tickToVictory(&combat, &draws, 500);
}

test "Talisman reserves and combines once without a recovery penalty" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
    combat.integration = .{ .host = host };
    var tape = Tape{};
    var draws = tape.init();
    try queueRound(&combat, .unite);
    const boundary = combat.uniteBoundaryFor(1) orelse return error.MissingUniteBoundary;
    try std.testing.expectEqual(@as(u8, 2), boundary.count);
    // The selected actor is the command owner; the catalogue's record order is
    // independent, so locate the non-leader participant instead of assuming
    // participants[0] is the leader.
    var partner: ?usize = null;
    for (boundary.participantsSlice()) |participant| {
        if (participant != 1) partner = participant;
    }
    try std.testing.expect(partner != null);
    try std.testing.expect(std.meta.eql(battle.Action{ .unite = 0 }, combat.actions[1].?));
    try std.testing.expect(std.meta.eql(battle.Action{ .assist = 1 }, combat.actions[partner.?].?));
    try combat.tickReplay(.{ .confirm = true }, &draws);
    var ticks: usize = 0;
    while (combat.enemy_hp[0] == 5000 and ticks < 500) : (ticks += 1) try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.enemy_hp[0] < 5000);
    // Impact commits HP before the action's return descriptor runs `finish`;
    // tick until the return descriptor has finished.
    while (combat.uniteBoundaryFor(1) != null and ticks < 1000) : (ticks += 1) try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.uniteBoundaryFor(1) == null);
    // Talisman uses the return chain without op40(7,100).
    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[2]);
    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[1]);
    try std.testing.expect(!combat.canUnite(2));
    try std.testing.expect(!unite_mod.allows(.attack));
    try std.testing.expect(unite_mod.allows(.defend));
}

test "imported Unite tracks preserve member clocks for either command owner" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const Case = struct { initiator: usize, participants: [2]usize, impact: u16, release: u16, duration: u16, recovery: u8, lethal: bool = false };
    for ([_]Case{
        .{ .initiator = 1, .participants = .{ 1, 2 }, .impact = 76, .release = 113, .duration = 189, .recovery = 0 },
        .{ .initiator = 2, .participants = .{ 1, 2 }, .impact = 68, .release = 105, .duration = 189, .recovery = 0 },
        .{ .initiator = 4, .participants = .{ 4, 5 }, .impact = 83, .release = 104, .duration = 143, .recovery = 2 },
        .{ .initiator = 5, .participants = .{ 4, 5 }, .impact = 83, .release = 104, .duration = 143, .recovery = 2 },
        .{ .initiator = 1, .participants = .{ 1, 2 }, .impact = 76, .release = 113, .duration = 189, .recovery = 0, .lethal = true },
        .{ .initiator = 4, .participants = .{ 4, 5 }, .impact = 83, .release = 104, .duration = 143, .recovery = 2, .lethal = true },
    }) |case| {
        const initiator = case.initiator;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
        combat.integration = .{ .host = host };
        const initial_hp: u16 = if (case.lethal) 1 else 5000;
        combat.enemy_hp[0] = initial_hp;
        combat.base_stats[initiator].speed = 999;
        var tape = Tape{};
        var draws = tape.init();
        combat.enterRoundMenu();
        combat.choose(initiator);
        combat.queue(.{ .unite = 0 });
        var guard: usize = 0;
        while (combat.phase == .command and guard < 12) : (guard += 1) combat.queue(.defend);
        try std.testing.expect(guard < 12);
        // Choosing a later owner leaves earlier menu slots outside the fixture's queue walk.
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        try combat.tickReplay(.{ .confirm = true }, &draws);
        guard = 0;
        while ((combat.active == null or combat.active.?.kind != .unite) and guard < 1000) : (guard += 1) try combat.tickReplay(.{}, &draws);
        try std.testing.expect(guard < 1000);
        try std.testing.expectEqual(initiator, combat.active.?.actor);
        // These prototype tracks use an actor-local origin; the production dispatch pass has its own gate.
        try std.testing.expectEqual(@as(u16, 0), combat.effectTicks());
        if (combat.coordinator) |clock| try std.testing.expectEqual(clock.elapsed, combat.active.?.started_at);
        for (case.participants) |participant| {
            try std.testing.expectEqual(combat.coordinator != null, combat.uniteMemberWaiting(participant));
            if (combat.coordinator != null) try std.testing.expectEqualDeep(combat.partyProfile(participant).sprite, battle.layout.actorLayout(combat, participant).sprite);
        }
        const impact = case.impact;
        try std.testing.expectEqual(impact, combat.impactTick());
        const handoff: u16 = if (case.participants[0] == 1) 137 else 92;
        try std.testing.expectEqual(handoff, combat.actionDuration());
        try std.testing.expectEqual(@as(?u16, handoff), combat.uniteHandoffTick());
        const started = combat.camera_ticks - combat.effectTicks();
        try std.testing.expectEqual(@as(?u16, case.release), combat.uniteTargetReleaseTick());
        var damage: ?u16 = null;
        while (combat.active != null and combat.active.?.kind == .unite and guard < 1500) : (guard += 1) {
            const tick = combat.effectTicks();
            try std.testing.expectEqual(tick >= case.release and !case.lethal, combat.active.?.target_released);
            try std.testing.expectEqual(tick < case.release or case.lethal, combat.coordinatorLocked(combat.active.?.target));
            for (case.participants) |participant| try std.testing.expectEqual(tick, combat.animationTick(participant));
            if (case.participants[0] == 4) {
                if (tick < 62) try std.testing.expect(combat.actor_camera == null) else {
                    const controller = combat.actor_camera.?;
                    const n: i32 = @min(tick - 62, 20);
                    const expected: i32 = if (tick >= 83) -128 * 4096 else 80 * 4096 + @divTrunc(-208 * @as(i32, 4096), 20) * n;
                    try std.testing.expectEqual(expected, controller.current[0][0]);
                    try std.testing.expectEqual(@as(u16, @intCast(20 - n)), controller.remaining[0]);
                    try std.testing.expectEqual(expected >> 12, battle.layout.currentCamera(combat).focus[0]);
                }
            } else try std.testing.expect(combat.actor_camera == null);

            if (tick < impact) try std.testing.expectEqual(initial_hp, combat.enemy_hp[0]);
            if (tick >= impact) {
                if (damage) |hp| try std.testing.expectEqual(hp, combat.enemy_hp[0]) else damage = combat.enemy_hp[0];
                try std.testing.expect(combat.enemy_hp[0] < initial_hp);
            }
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expect(guard < 1500 and damage != null);
        try std.testing.expectEqual(@as(u32, handoff), combat.camera_ticks - started);
        try std.testing.expect(combat.hasUniteReturns());
        try std.testing.expect(combat.uniteBoundaryFor(initiator) != null);
        var overlapped = false;
        while (combat.hasUniteReturns() and guard < 1500) : (guard += 1) {
            const elapsed = combat.camera_ticks - started;
            if (combat.active != null and combat.active.?.kind != .unite) overlapped = true;
            var reaction_only = combat;
            reaction_only.active = null;
            try std.testing.expectEqual(elapsed < case.release or case.lethal, reaction_only.coordinatorLocked(combat.partyCount()));
            for (case.participants) |participant| {
                const duration = combat.partyProfile(participant).uniteTrack(null).?.motion.duration;
                try std.testing.expectEqual(elapsed < duration, combat.uniteReturnFor(participant) != null);
                try std.testing.expectEqual(elapsed < duration, combat.coordinatorLocked(participant));
                if (elapsed < duration) {
                    try std.testing.expectEqual(@as(u16, @intCast(elapsed)), combat.animationTick(participant));
                    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[participant]);
                    const motion = combat.actionMotion(participant).?;
                    try std.testing.expectEqual(duration, motion.duration);
                    try std.testing.expectEqual(combat.partyProfile(participant).uniteTrack(null).?.attack.ptr, combat.attackFrames(participant).ptr);
                    _ = battle.layout.actorLayout(combat, participant);
                }
            }
            try std.testing.expectEqual(damage.?, combat.enemy_hp[0]);
            if (initiator == 4 and !case.lethal and elapsed + 1 == case.duration) {
                const before = try stateBytes(combat);
                defer allocator.free(before);
                var short = draws;
                short.values = draws.values[0 .. draws.cursor + 1];
                const cursor = short.cursor;
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short));
                const after = try stateBytes(combat);
                defer allocator.free(after);
                try std.testing.expectEqualStrings(before, after);
                try std.testing.expectEqual(cursor, short.cursor);
                const identity = try combat_session.fingerprint(combat);
                const entry = combat_session.Entry{ .id = "unite-return", .receipt = "1", .content_id = "fixture", .encounter_id = combat.content.encounters[combat.encounter].id, .content_fingerprint = &identity };
                const session = combat_session.Session{ .entry = entry, .state = combat, .draws = draws, .integration = host };
                const checkpoint = try session.capture(draws);
                var replay_members: [6]battle.Member = undefined;
                var resumed = try combat_session.Session.begin(entry, combat, &replay_members, draws);
                var replay_draws = draws;
                try resumed.restore(checkpoint, &replay_draws);
                try resumed.tick(.{}, &replay_draws);
                var forward = combat;
                var forward_members: [6]battle.Member = undefined;
                @memcpy(&forward_members, combat.progress.party);
                forward.progress.party = &forward_members;
                var forward_draws = draws;
                try forward.tickReplay(.{}, &forward_draws);
                const expected = try stateBytes(forward);
                defer allocator.free(expected);
                const actual = try stateBytes(resumed.state);
                defer allocator.free(actual);
                try std.testing.expectEqualStrings(expected, actual);
                try std.testing.expectEqual(forward_draws.cursor, replay_draws.cursor);
                const unchanged = try stateBytes(combat);
                defer allocator.free(unchanged);
                try std.testing.expectEqualStrings(before, unchanged);
            }
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expect(guard < 1500);
        try std.testing.expectEqual(@as(u32, case.duration), combat.camera_ticks - started);
        if (!case.lethal) try std.testing.expect(overlapped);
        try std.testing.expect(combat.uniteBoundaryFor(initiator) == null);
        for (case.participants) |participant| try std.testing.expectEqual(case.recovery, combat.unbalanced[participant]);
    }
}

test "a mid-update draw exhaustion restores the exact state and draw cursor" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
    combat.integration = .{ .host = host };
    var tape = Tape{};
    var draws = tape.init();
    try queueRound(&combat, .spell);
    try combat.tickReplay(.{ .confirm = true }, &draws);
    const saved = try stateBytes(combat);
    defer allocator.free(saved);
    var short: [1]u15 = .{1234};
    var short_draws = rules.Draws{ .values = &short };
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
    const restored = try stateBytes(combat);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(saved, restored);
    try std.testing.expectEqual(short_draws.cursor, @as(usize, 0));
}

test "a mid-round checkpoint continues in a fresh session without drift" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();

    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
    combat.integration = .{ .host = host };
    var tape = Tape{};
    var draws = tape.init();
    var fingerprint = try combat_session.fingerprint(combat);
    const entry: combat_session.Entry = .{
        .id = "battle-integration",
        .receipt = "1",
        .content_id = "fixture",
        .encounter_id = combat.content.encounters[combat.encounter].id,
        .content_fingerprint = fingerprint[0..],
    };
    var scratch: [6]battle.Member = undefined;
    var session = try combat_session.Session.begin(entry, combat, &scratch, draws);
    session.integration = host;
    session.state.integration = .{ .host = host };

    // Ordinary menu path: confirm the intro, queue the first round, confirm it.
    try session.tick(.{ .confirm = true }, &draws);
    try std.testing.expectEqual(battle.Phase.command, session.state.phase);
    session.state.choose(firstLiving(session.state, true).?);
    var guard: usize = 0;
    while (session.state.phase == .command and guard < 12) : (guard += 1) {
        if (session.state.canAttackTarget(session.state.actor, 0)) session.state.queue(.{ .attack = 0 }) else session.state.queue(.defend);
    }
    try session.tick(.{ .confirm = true }, &draws);
    var warmup: usize = 0;
    while (session.state.phase == .resolving and warmup < 7) : (warmup += 1) try session.tick(.{}, &draws);
    const checkpoint = try session.capture(draws);
    const checkpoint_cursor = draws.cursor;

    try tickToVictory(&session.state, &draws, 4000);
    const expected = try stateBytes(session.state);
    defer allocator.free(expected);
    const expected_cursor = draws.cursor;

    // Fresh session over the same content and a reset copy of the same tape.
    var members2: [6]battle.Member = undefined;
    var combat2 = try battle.State.init(fixture.view, fixture.items.value, &members2, 0x5355494b);
    combat2.integration = .{ .host = host };
    var tape2 = Tape{};
    var draws2 = tape2.init();
    var fingerprint2 = try combat_session.fingerprint(combat2);
    const entry2: combat_session.Entry = .{
        .id = "battle-integration",
        .receipt = "1",
        .content_id = "fixture",
        .encounter_id = combat2.content.encounters[combat2.encounter].id,
        .content_fingerprint = fingerprint2[0..],
    };
    var scratch2: [6]battle.Member = undefined;
    var session2 = try combat_session.Session.begin(entry2, combat2, &scratch2, draws2);
    session2.integration = host;
    try session2.restore(checkpoint, &draws2);
    try std.testing.expectEqual(checkpoint_cursor, draws2.cursor);
    try tickToVictory(&session2.state, &draws2, 4000);
    const resumed = try stateBytes(session2.state);
    defer allocator.free(resumed);
    try std.testing.expectEqualStrings(expected, resumed);
    try std.testing.expectEqual(expected_cursor, draws2.cursor);
}

test "rune/weapon identity survives a transition guard and a substitution is refused" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
    combat.integration = .{ .host = host };
    combat.progress.party[2].name = "Renamed display text";
    const source = try world_battle.loadoutOf(host, &combat, 2);
    try std.testing.expectEqual(@as(u16, 6), source.member);
    combat.progress.party[2].rune_charges[0] += 1;
    const spent = try world_battle.loadoutOf(host, &combat, 2);
    const carried = try techniques_mod.carry.carry(source, spent);
    try std.testing.expectEqual(source.rune.byte, carried.rune.byte);
    try std.testing.expectEqual(source.weapon_level, carried.weapon_level);
    var changed = spent;
    changed.rune.byte = if (spent.rune.byte == 9) 10 else 9;
    try std.testing.expectError(error.RuneChanged, techniques_mod.carry.carry(source, changed));
    var leveled = spent;
    leveled.weapon_level +|= 1;
    try std.testing.expectError(error.LoadoutChanged, techniques_mod.carry.carry(source, leveled));
}

test "reward money saturates at the shared cap and experience levels are bounded" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 0x5355494b);
    combat.integration = .{ .host = host };
    combat.progress.money = field.game_state.max_money - 1;
    combat.experience[0] = std.math.maxInt(u32) - 5;
    var tape = Tape{};
    var draws = tape.init();
    try queueRound(&combat, .ordinary);
    try combat.tickReplay(.{ .confirm = true }, &draws);
    try tickToVictory(&combat, &draws, 4000);
    try std.testing.expectEqual(field.game_state.max_money, combat.progress.money);
    try std.testing.expectEqual(@as(u32, 1), combat.reward_received);
    try std.testing.expect(combat.experience[0] < 1000 or combat.levels[0] == 99);
}

test "the spell plan and bridge expose the same reviewed catalogue the spell path uses" {
    const host = try hostFixture();
    defer host.deinit();
    const ruleset = host.spellRules();
    try std.testing.expectEqual(@as(usize, 33), ruleset.counts().supported + ruleset.counts().partial + ruleset.counts().blocked);
    const index = host.spellIndexForName("Flaming Arrows").?;
    try std.testing.expectEqual(@as(u8, 1), ruleset.spells[index].native_id);
    try std.testing.expectEqual(spells_mod.rules.family_version, spells_mod.plan.family_version);
    try std.testing.expectEqual(@as(usize, 32), host.uniteCatalogue().provenCount());
    try std.testing.expectEqual(@as(usize, 0), host.uniteCatalogue().blockedCount());
}

test "normal ticks use the integrated spell path and retain the saved PRNG sequence" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var live_members: [6]battle.Member = undefined;
    var replay_members: [6]battle.Member = undefined;
    var live = try battle.State.init(fixture.view, fixture.items.value, &live_members, 8123);
    var replay = try battle.State.init(fixture.view, fixture.items.value, &replay_members, 8123);
    live.integration = .{ .host = host };
    replay.integration = .{ .host = host };
    try queueRound(&live, .spell);
    try queueRound(&replay, .spell);
    var draws = rules.Draws{ .prng = replay.random };
    live.tick(.{ .confirm = true });
    try replay.tickReplay(.{ .confirm = true }, &draws);
    var ticks: usize = 0;
    while (live.enemy_hp[0] == 5000 and ticks < 500) : (ticks += 1) {
        live.tick(.{});
        try replay.tickReplay(.{}, &draws);
    }
    try std.testing.expect(ticks < 500);
    try std.testing.expectEqual(@as(u16, 4736), live.enemy_hp[0]);
    try std.testing.expectEqualDeep(replay.enemy_hp, live.enemy_hp);
    try std.testing.expectEqualDeep(replay_members, live_members);
    try std.testing.expectEqualDeep(draws.prng.?, live.random);
}

test "rune source identity survives a compacted and reordered catalogue" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var systems = fixture.view.systems.?;
    const fire = systems.runes[0];
    var compact = [_]rules.Rune{
        systems.runes[7],                                                                                  fire,
        .{ .id = "masked_rune_32", .name = "??????", .spell_names = @splat("-"), .spells = @splat(null) }, .{ .id = "soul_eater", .name = "Soul Eater", .spell_names = @splat("-"), .spells = @splat(null) },
    };
    systems.runes = &compact;
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    combat.content.systems = systems;
    combat.runes[0] = 1;
    try std.testing.expectEqual(@as(?u8, 2), combat.runeByteFor(0));
    combat.runes[0] = 0;
    try std.testing.expectEqual(@as(?u8, 9), combat.runeByteFor(0));
    combat.runes[0] = 2;
    try std.testing.expectEqual(@as(?u8, 32), combat.runeByteFor(0));
    combat.runes[0] = 3;
    try std.testing.expectEqual(@as(?u8, 1), combat.runeByteFor(0));
}

test "all exported source-rule spells reach their reviewed effects through the normal owner" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const systems = fixture.view.systems.?;
    var covered: usize = 0;
    for (systems.spells, 0..) |spell, spell_index| {
        if (spell.kind != .source_rule) continue;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
        var rune_index: ?usize = null;
        for (systems.runes, 0..) |rune, index| {
            for (rune.spells) |slot| if (slot == spell_index) {
                rune_index = index;
            };
        }
        // Soul Eater rules are testable before its story attachment is recovered.
        var single_rune = [_]rules.Rune{.{ .id = "soul_eater", .name = "Soul Eater", .spell_names = .{ spell.name, "-", "-", "-" }, .spells = .{ spell_index, null, null, null } }};
        if (rune_index) |index| {
            combat.runes[0] = index;
        } else {
            var rule_view = systems;
            rule_view.runes = &single_rune;
            combat.content.systems = rule_view;
            combat.runes[0] = 0;
        }
        combat.progress.party[0].rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party[0].hp = 1;
        var effect = battle.Effect{ .actor = 0, .target = if (spell.allies) 0 else combat.partyCount(), .kind = .cast, .spell = spell_index };
        // A host-free caller must never interpret a complex rule as generic healing.
        combat.applySpell(&effect);
        try std.testing.expectEqual(@as(@FieldType(battle.Effect, "kind"), .unavailable), effect.kind);
        try std.testing.expectEqual(@as(u8, 9), combat.progress.party[0].rune_charges[combat.spellTier(0, spell_index).?]);
        combat.integration = .{ .host = host };
        effect.kind = .cast;
        combat.applySpell(&effect);
        try std.testing.expect(effect.kind != .unavailable);
        try std.testing.expectEqual(@as(u8, 8), combat.progress.party[0].rune_charges[combat.spellTier(0, spell_index).?]);
        covered += 1;
    }
    try std.testing.expectEqual(@as(usize, 12), covered);
}

test "normal battle owner reserves and resolves three and four member Unites" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const cases = [_]struct { names: []const []const u8, ids: []const []const u8, label: []const u8, record: u8 }{
        .{ .names = &.{ "Kirkis", "Stallion", "Sylvina" }, .ids = &.{ "kirkis", "stallion", "sylvina" }, .label = "Elf attack", .record = 3 },
        .{ .names = &.{ "Maas", "Moose", "Meese", "Mace" }, .ids = &.{ "maas", "moose", "meese", "mace" }, .label = "Blacksmith attack", .record = 5 },
    };
    for (cases) |case| {
        // Borrow stats and motion only; membership uses stable character IDs.
        var profiles: [11]battle.Profile = undefined;
        var profile_count = fixture.view.party.len;
        @memcpy(profiles[0..profile_count], fixture.view.party);
        var initial: [6][]const u8 = undefined;
        for (0..6) |i| initial[i] = fixture.view.initialProfile(i).id;
        for (case.ids, case.names, 0..) |id, name, i| {
            const index = for (profiles[0..profile_count], 0..) |profile, j| {
                if (std.mem.eql(u8, profile.id, id)) break j;
            } else blk: {
                const j = profile_count;
                profiles[j] = fixture.view.party[i];
                profiles[j].id = id;
                profile_count += 1;
                break :blk j;
            };
            profiles[index].name = name;
            initial[i] = id;
        }
        var content = fixture.view;
        content.party = profiles[0..profile_count];
        content.schema = "suikoden-battle-trial/28";
        content.medicine_timings = &.{};
        for (profiles[0..profile_count]) |*profile| profile.item_art = null;
        content.initial_party = &initial;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, fixture.items.value, &members, 1);
        combat.integration = .{ .host = host };
        for (0..case.names.len) |i| combat.progress.party[i].name = "Display alias";
        try std.testing.expect(combat.uniteDefinition(0) == null);
        combat.actor = 0;
        combat.phase = .unite_target;
        combat.tick(.{ .right = true });
        try std.testing.expectEqual(@as(?u8, case.record), combat.selected_unites[0]);
        try std.testing.expectEqualStrings(case.label, combat.uniteName(0));
        try queueRound(&combat, .unite);
        const boundary = combat.uniteBoundaryFor(0) orelse return error.MissingUniteBoundary;
        try std.testing.expectEqual(case.names.len, boundary.count);
        for (1..case.names.len) |i| try std.testing.expectEqual(battle.Action{ .assist = 0 }, combat.actions[i].?);
        combat.tick(.{ .confirm = true });
        var ticks: usize = 0;
        while (combat.enemy_hp[0] == 5000 and ticks < 500) : (ticks += 1) combat.tick(.{});
        try std.testing.expect(ticks < 500);
        try std.testing.expect(combat.enemy_hp[0] < 5000);
        try std.testing.expectEqualStrings(case.label, combat.uniteName(0));
    }
}

test "Unite draw exhaustion restores the entire production-owner update" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    combat.integration = .{ .host = host };
    var tape = Tape{};
    var draws = tape.init();
    try queueRound(&combat, .unite);
    try combat.tickReplay(.{ .confirm = true }, &draws);
    var ticks: usize = 0;
    while (ticks < 500) : (ticks += 1) {
        if (combat.active) |effect| if (effect.unite_boundary and combat.action_ticks + 1 == combat.impactTick()) break;
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expect(ticks < 500);
    const before = try stateBytes(combat);
    defer allocator.free(before);
    var empty = rules.Draws{};
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &empty));
    const after = try stateBytes(combat);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(usize, 0), empty.cursor);
}

test "Sleep source round continuation applies poison protection and balloons without a party wake draw" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json_c);
    defer source.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    combat.integration = .{ .host = host };
    try sourceRoundBoundary(&combat, source.value);
    combat.progress.party[0].hp = 1;
    combat.progress.party[0].status = .poisoned;
    combat.progress.party[1].balloons = 3;
    const departed_hp = combat.progress.party[1].hp;
    combat.progress.party[2].status = .poisoned;
    combat.progress.party[2].hp = 100;
    combat.protection[2] = 2;
    combat.unbalanced[2] = 1;
    combat.asleep[2] = 1;
    combat.progress.party[3].hp = 6;
    combat.progress.party[3].status = .poisoned;
    combat.protection[3] = 1;
    combat.runes[4] = combat.content.systems.?.runeIndex("sunbeam").?;
    combat.progress.party[4].hp = 50;
    combat.progress.party[4].status = .poisoned;
    combat.progress.party[5].hp = 100;
    combat.progress.party[5].status = .poisoned;
    var draws = rules.Draws{ .values = &.{} };
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(@FieldType(battle.Coordinator, "stage"), .round_setup), combat.coordinator.?.stage);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
    try std.testing.expectEqual(@as(u32, 2), combat.round);
    try std.testing.expectEqual(@as(u16, 0), combat.progress.party[0].hp);
    try std.testing.expectEqual(field.game_state.Status.unconscious, combat.progress.party[0].status);
    try std.testing.expect(combat.departed[1]);
    try std.testing.expectEqual(departed_hp, combat.progress.party[1].hp);
    try std.testing.expectEqual(@as(u16, 100), combat.progress.party[2].hp);
    try std.testing.expectEqual(@as(u8, 1), combat.protection[2]);
    try std.testing.expectEqual(@as(u8, 1), combat.asleep[2]);
    try std.testing.expectEqual(@as(usize, 1), combat.formationSlot(3));
    try std.testing.expectEqual(@as(u16, 0), combat.hp(3));
    try std.testing.expectEqual(@as(u16, 50), combat.progress.party[4].hp);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    const after = combat.hp(5);
    try std.testing.expectEqual(@as(u16, 100) - rules.battlePoison(combat.progress.party[5].max_hp), after);
    for (0..3) |_| try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(after, combat.hp(5));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "Sleep source wake rolls belong only to living enemies and preserve percentage endpoints" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    try std.testing.expectEqual(@as(?u8, 50), combat.content.systems.?.sleep_recovery_percent);
    var empty = rules.Draws{ .values = &.{} };
    combat.replay_draws = &empty;
    for (0..combat.partyCount()) |actor| {
        combat.acted[actor] = false;
        try std.testing.expect(combat.inflictStatus(actor, .sleep));
        try std.testing.expect(combat.acted[actor]);
        try std.testing.expect(!combat.inflictStatus(actor, .sleep));
        for (0..4) |_| combat.recoverSleep(actor);
        try std.testing.expectEqual(@as(u8, 1), combat.asleep[actor]);
    }
    try std.testing.expectEqual(@as(usize, 0), empty.cursor);
    try std.testing.expect(!combat.replay_exhausted);
    const enemy = combat.partyCount();
    for ([_]u15{ 0, 16383, 16384, 32767 }) |roll| {
        combat.asleep[enemy] = 1;
        var draws = rules.Draws{ .values = &.{roll} };
        combat.replay_draws = &draws;
        combat.recoverSleep(enemy);
        try std.testing.expectEqual(@as(u8, if (roll < 16384) 0 else 1), combat.asleep[enemy]);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
    }
    combat.enemy_hp[0] = 0;
    combat.asleep[enemy] = 1;
    combat.replay_draws = &empty;
    combat.recoverSleep(enemy);
    try std.testing.expectEqual(@as(u8, 1), combat.asleep[enemy]);
    try std.testing.expectEqual(@as(usize, 0), empty.cursor);
    try std.testing.expect(!combat.replay_exhausted);
    combat.replay_draws = null;
}

test "Sleep acquired after selection cancels every queued party command without spending resources" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const commands = [_]battle.Action{ .{ .attack = 0 }, .{ .rune_attack = 0 }, .defend, .{ .item = .{ .slot = 0, .target = 0 } }, .{ .spell = .{ .index = 0, .target = 0 } }, .{ .unite = 0 }, .{ .assist = 0 } };
    for (0..6) |actor| for (commands) |command| for ([_]bool{ false, true }) |scripted| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
        combat.phase = .resolving;
        combat.active = null;
        combat.actions[actor] = command;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = actor };
        if (scripted) {
            var acquisition = rules.Draws{ .values = &.{0} };
            combat.replay_draws = &acquisition;
            try combat.requestActorStatus(actor, .{ .kind = .sleep, .threshold_percent = 100 });
            try std.testing.expectEqual(@as(usize, 1), acquisition.cursor);
            combat.replay_draws = null;
        } else try std.testing.expect(combat.inflictStatus(actor, .sleep));
        const before = members;
        const enemy_hp = combat.enemy_hp;
        var draws = rules.Draws{ .values = &.{} };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active == null and combat.medicine_action == null and !combat.unite_vm.hasActors());
        try std.testing.expect(combat.coordinator.?.stage == .select and combat.coordinator.?.completed);
        try std.testing.expect(combat.acted[actor]);
        try std.testing.expectEqual(@as(u16, 0), combat.coordinator.?.remaining);
        try std.testing.expectEqualDeep(before, members);
        try std.testing.expectEqualDeep(enemy_hp, combat.enemy_hp);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    };
}

test "Queued rune actions wait for target release and retire on rune block or recovery" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();

    const Case = struct { actor: usize, rune: usize, command: battle.Action };
    const cases = [_]Case{
        .{ .actor = 0, .rune = 0, .command = .{ .spell = .{ .index = 0, .target = 0 } } },
        .{ .actor = 2, .rune = 7, .command = .{ .rune_attack = 0 } },
    };
    for (cases) |case| for ([_]bool{ false, true }) |recovering| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        combat.encounter = 1;
        combat.startEncounter();
        combat.runes[case.actor] = case.rune;
        combat.progress.party[case.actor].rune_charges[0] = 1;
        switch (case.command) {
            .spell => |cast| try std.testing.expect(combat.canCast(case.actor, cast.index)),
            .rune_attack => try std.testing.expect(combat.canPhysicalRune(case.actor)),
            else => unreachable,
        }
        combat.phase = .resolving;
        combat.actions[case.actor] = case.command;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = case.actor };
        if (recovering) for ([_]bool{ true, false }) |coordinated| {
            var waiting = combat;
            const replacement = waiting.partyCount() + 1;
            waiting.enemy_hp[0] = 0;
            waiting.front_projectiles[0] = .{ .actor = replacement, .target = 1 };
            if (coordinated) {
                const random = waiting.random;
                waiting.advanceCoordinator();
                try std.testing.expectEqual(.dispatch, waiting.coordinator.?.stage);
                try std.testing.expectEqual(case.actor, waiting.coordinator.?.current_actor);
                try std.testing.expectEqualDeep(random, waiting.random);
            } else {
                waiting.coordinator = null;
                waiting.acted = @splat(true);
                waiting.acted[case.actor] = false;
                waiting.nextAction();
                try std.testing.expectEqual(@as(?usize, case.actor), waiting.pending_party_actor);
            }
            const random = waiting.random;
            if (coordinated) waiting.advanceCoordinator() else waiting.nextAction();
            try std.testing.expect(waiting.active == null and !waiting.acted[case.actor]);
            try std.testing.expectEqualDeep(random, waiting.random);
            waiting.front_projectiles[0] = null;
            if (coordinated) waiting.advanceCoordinator() else waiting.nextAction();
            try std.testing.expectEqual(replacement, waiting.active.?.target);
            try std.testing.expectEqual(waiting.partyCount(), waiting.active.?.retargeted_from.?);
            try std.testing.expect(waiting.pending_party_actor == null);
        };
        var acquisition = rules.Draws{ .values = &.{0} };
        combat.replay_draws = &acquisition;
        if (recovering) {
            try combat.requestUniteRecovery(case.actor, 2);
        } else {
            try combat.requestActorStatus(case.actor, .{ .kind = .rune_blocked, .threshold_percent = 100 });
        }
        try std.testing.expectEqual(@as(usize, 1), acquisition.cursor);
        combat.replay_draws = null;
        try std.testing.expect(if (recovering) combat.unbalanced[case.actor] == 2 else combat.rune_blocked[case.actor]);
        try std.testing.expect(!combat.acted[case.actor]);

        const before = members;
        const enemy_hp = combat.enemy_hp;
        var draws = rules.Draws{ .values = &.{} };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.acted[case.actor] and combat.coordinator.?.completed);
        try std.testing.expectEqual(.select, combat.coordinator.?.stage);
        try std.testing.expect(combat.active == null and !combat.unite_vm.hasActors());
        try std.testing.expectEqualDeep(before, members);
        try std.testing.expectEqualDeep(enemy_hp, combat.enemy_hp);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    };
}

test "enemy knocked out after selection releases dispatch without taking an action" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    const enemy = combat.partyCount();
    combat.phase = .resolving;
    combat.coordinator = .{ .stage = .check, .current_actor = enemy, .cached = .{ .actor = enemy }, .completed = true };
    combat.advanceCoordinator();
    try std.testing.expectEqual(.dispatch, combat.coordinator.?.stage);

    combat.enemy_hp[0] = 0;
    const before = members;
    var draws = rules.Draws{ .values = &.{} };
    try combat.tickReplay(.{}, &draws);

    try std.testing.expect(combat.acted[enemy] and combat.coordinator.?.completed);
    try std.testing.expectEqual(.select, combat.coordinator.?.stage);
    try std.testing.expect(combat.active == null and combat.pending_enemy_actor == null);
    try std.testing.expectEqualDeep(before, members);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "queued item waits for its owner's knockout to settle and skips a downed owner" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    const owner = 0;
    const target = 1;
    members[owner].inventory.slots = @splat(null);
    members[owner].inventory.slots[0] = .{ .id = .medicine, .uses = 1 };
    combat.phase = .resolving;
    combat.actions[owner] = .{ .item = .{ .slot = 0, .target = target, .id = .medicine } };
    combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
    members[owner].hp = 0;
    combat.markPartyKnockout(owner);

    const before = combat.coordinator.?;
    combat.advanceCoordinator();
    try std.testing.expectEqualDeep(before, combat.coordinator.?);
    try std.testing.expect(!combat.acted[owner] and combat.medicine_action == null);
    try std.testing.expectEqual(@as(u16, 1), members[owner].inventory.slots[0].?.uses);

    try std.testing.expect(combat.commitPartyKnockout(owner));
    const settled = members;
    var draws = rules.Draws{ .values = &.{} };
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.acted[owner] and combat.coordinator.?.completed);
    try std.testing.expectEqual(.select, combat.coordinator.?.stage);
    try std.testing.expect(combat.active == null and combat.medicine_action == null);
    try std.testing.expectEqualDeep(settled, members);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "queued item keeps its selected stack when automatic revival compacts inventory" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    const owner = 0;
    const target = 1;
    members[owner].inventory.slots = @splat(null);
    members[owner].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
    members[owner].inventory.slots[1] = .{ .id = .medicine, .uses = 1 };
    members[owner].inventory.slots[2] = .{ .id = .medicine, .uses = 3 };
    combat.phase = .resolving;
    combat.actions[owner] = .{ .item = .{ .slot = 2, .target = target, .id = .medicine } };
    combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
    members[owner].hp = 0;
    combat.markPartyKnockout(owner);
    try std.testing.expect(!combat.commitPartyKnockout(owner));
    try std.testing.expectEqual(@as(usize, 1), combat.actions[owner].?.item.slot);

    var draws = rules.Draws{ .values = &.{} };
    while (combat.revivals[owner] != null) {
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.medicine_action == null);
        if (combat.camera_ticks > combat.rules.automatic_revival.?.release_delay + 1) return error.RevivalDidNotRelease;
    }
    try std.testing.expect(combat.hp(owner) > 0);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(.item_wait, combat.coordinator.?.stage);
    try std.testing.expectEqual(@as(usize, target), combat.medicine_action.?.target);
    try std.testing.expectEqual(@as(usize, 2), members[owner].inventory.count());
    try std.testing.expectEqual(@as(u16, 1), members[owner].inventory.slots[0].?.uses);
    try std.testing.expectEqual(@as(u16, 2), members[owner].inventory.slots[1].?.uses);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "Sleep source rounds skip sleeping actors before priority and roll back a later enemy wake" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json_c);
    defer source.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    combat.integration = .{ .host = host };
    try sourceRoundBoundary(&combat, source.value);
    const count = combat.partyCount() + combat.enemyCount();
    for (0..count) |actor| combat.asleep[actor] = 1;
    combat.progress.party[0].status = .poisoned;
    const hp = combat.hp(0);
    const poison = rules.battlePoison(combat.progress.party[0].max_hp);
    const charges = combat.progress.party[0].rune_charges;
    const inventory = combat.progress.party[0].inventory;
    var values: [16]u15 = @splat(32767);
    var draws = rules.Draws{ .values = &values };
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.coordinator.?.stage == .round_setup);
    const before = try stateBytes(combat);
    defer allocator.free(before);
    const before_members = members;
    draws.values = values[0..1];
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    const after = try stateBytes(combat);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualDeep(before_members, members);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    draws.values = &values;
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(u32, 2), combat.round);
    try std.testing.expectEqual(hp - poison, combat.hp(0));
    try std.testing.expectEqual(combat.enemyCount(), draws.cursor);
    try std.testing.expect(combat.phase == .battle_menu);
    try combat.tickReplay(.{ .confirm = true }, &draws);
    for (0..combat.partyCount()) |_| combat.queue(.defend);
    try std.testing.expect(combat.phase == .confirm_round);
    try combat.tickReplay(.{ .confirm = true }, &draws);
    try std.testing.expect(combat.round_start_pending);
    try combat.tickReplay(.{}, &draws);
    for (0..count) |actor| try std.testing.expect(combat.acted[actor]);
    for (0..300) |_| {
        if (combat.phase != .resolving) break;
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expect(combat.phase == .battle_menu and combat.round == 3);
    for (0..count) |actor| try std.testing.expectEqual(@as(u8, 1), combat.asleep[actor]);
    try std.testing.expectEqual(hp - poison * 2, combat.hp(0));
    try std.testing.expectEqual(combat.enemyCount() * 2 + 1, draws.cursor);
    try std.testing.expectEqualDeep(charges, combat.progress.party[0].rune_charges);
    try std.testing.expectEqualDeep(inventory, combat.progress.party[0].inventory);
}

test "third-balloon departure of the last active members reaches defeat with HP retained" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json_c);
    defer source.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    combat.integration = .{ .host = host };
    try sourceRoundBoundary(&combat, source.value);
    for (combat.progress.party) |*member| member.balloons = 3;
    var draws = rules.Draws{};
    try combat.tickReplay(.{}, &draws);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(battle.Phase.defeat, combat.phase);
    for (combat.progress.party, 0..) |member, i| {
        try std.testing.expect(member.hp > 0);
        try std.testing.expect(combat.departed[i]);
    }
    try std.testing.expect(combat.hasDepartureFlights());
    for (0..97) |_| {
        if (!combat.hasDepartureFlights()) break;
        combat.tick(.{ .restart = true });
    }
    try std.testing.expectEqual(battle.Phase.defeat, combat.phase);
    try std.testing.expect(!combat.hasDepartureFlights());
}

test "Fisherman recovery survives the next boundary and clears on the following boundary" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    combat.integration = .{ .host = host };
    combat.unbalanced[1] = 1; // Keep Talisman unavailable for this command round.
    try queueRound(&combat, .unite);
    try std.testing.expect(combat.uniteBoundaryFor(4) != null);
    var tape = Tape{};
    var draws = tape.init();
    try combat.tickReplay(.{ .confirm = true }, &draws);
    var ticks: usize = 0;
    while (combat.uniteBoundaryFor(4) != null and ticks < 1000) : (ticks += 1) try combat.tickReplay(.{}, &draws);
    try std.testing.expect(ticks < 1000);
    try std.testing.expectEqual(@as(u8, 2), combat.unbalanced[4]);
    try std.testing.expectEqual(@as(u8, 2), combat.unbalanced[5]);
    combat.applyRoundBoundaryStatuses();
    try std.testing.expectEqual(@as(u8, 1), combat.unbalanced[4]);
    try std.testing.expect(!combat.canAttackTarget(4, 0));
    combat.applyRoundBoundaryStatuses();
    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[4]);
    try std.testing.expect(combat.canAttackTarget(4, 0));
}

test "normal owner advances Master pupil through three distinct target impacts" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var profiles: [8]battle.Profile = undefined;
    @memcpy(profiles[0..7], fixture.view.party);
    profiles[7] = profiles[1];
    profiles[7].id = "kai";
    profiles[7].name = "Kai";
    var initial: [6][]const u8 = undefined;
    for (0..6) |i| initial[i] = fixture.view.initialProfile(i).id;
    initial[1] = "kai";
    fixture.view.party = &profiles;
    fixture.view.schema = "suikoden-battle-trial/28";
    fixture.view.medicine_timings = &.{};
    for (&profiles) |*profile| profile.item_art = null;
    fixture.view.initial_party = &initial;
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    combat.integration = .{ .host = host };
    combat.encounter = 1;
    combat.startEncounter();
    try queueRound(&combat, .unite);
    try std.testing.expectEqualStrings("Master pupil attack", combat.uniteName(0));
    var tape = Tape{};
    var draws = tape.init();
    try combat.tickReplay(.{ .confirm = true }, &draws);
    var ticks: usize = 0;
    var failed_later_hit = false;
    var first_changed = false;
    var both_changed = false;
    while (combat.uniteBoundaryFor(0) != null and ticks < 1000) : (ticks += 1) {
        if (combat.hasUniteSequence() and combat.effectTicks() == 145 and !failed_later_hit) {
            const before = try stateBytes(combat);
            defer allocator.free(before);
            var empty = rules.Draws{};
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &empty));
            const after = try stateBytes(combat);
            defer allocator.free(after);
            try std.testing.expectEqualStrings(before, after);
            failed_later_hit = true;
        }
        try combat.tickReplay(.{}, &draws);
        if (combat.enemy_hp[0] < 5000 and combat.enemy_hp[1] == 5000) first_changed = true;
        if (combat.enemy_hp[0] < 5000 and combat.enemy_hp[1] < 5000 and combat.enemy_hp[2] == 5000) both_changed = true;
    }
    try std.testing.expect(ticks < 1000);
    try std.testing.expect(first_changed and both_changed and failed_later_hit);
    for (combat.enemy_hp[0..3]) |hp| try std.testing.expect(hp < 5000);
    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[0]);
    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[1]);
}

test "Master pupil waits for global locks then snapshots living enemies when its action starts" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var profiles: [8]battle.Profile = undefined;
    @memcpy(profiles[0..7], fixture.view.party);
    profiles[7] = profiles[1];
    profiles[7].id = "kai";
    profiles[7].name = "Kai";
    var initial: [6][]const u8 = undefined;
    for (0..6) |i| initial[i] = fixture.view.initialProfile(i).id;
    initial[1] = "kai";
    fixture.view.party = &profiles;
    fixture.view.schema = "suikoden-battle-trial/28";
    fixture.view.medicine_timings = &.{};
    for (&profiles) |*profile| profile.item_art = null;
    fixture.view.initial_party = &initial;
    for (0..2) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
        combat.integration = .{ .host = host };
        combat.encounter = 1;
        combat.startEncounter();
        if (scenario == 1) combat.enemy_hp[2] = 0;
        try queueRound(&combat, .unite);
        const before = combat.uniteBoundaryFor(0).?.sequence.?.pending;
        if (scenario == 0) {
            try std.testing.expect(before[0] and before[1] and before[2]);
            combat.enemy_hp[0] = 0;
            combat.front_projectiles[0] = .{ .actor = combat.partyCount() + 1, .target = 0 };
            try std.testing.expect(combat.coordinatorLocked(combat.partyCount() + 1));
            const acted = combat.acted;
            try std.testing.expect(!combat.beginUniteAction(0, 0));
            try std.testing.expectEqualDeep(acted, combat.acted);
            try std.testing.expectEqualDeep(before, combat.uniteBoundaryFor(0).?.sequence.?.pending);
            try std.testing.expect(combat.active == null);
            combat.front_projectiles[0] = null;
        } else {
            try std.testing.expect(!before[2]);
            combat.enemy_hp[2] = 5000;
        }
        try std.testing.expect(combat.beginUniteAction(0, 0));
        const after = combat.uniteBoundaryFor(0).?.sequence.?.pending;
        if (scenario == 0) {
            try std.testing.expect(!after[0] and after[1] and after[2]);
        } else {
            try std.testing.expect(after[0] and after[1] and after[2]);
        }
    }
}

test "late coordinator spells keep their action clock and serialize a faster assisting Unite" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    combat.integration = .{ .host = host };
    combat.choose(0);
    combat.queue(.{ .spell = .{ .index = 0, .target = 0 } });
    combat.queue(.{ .unite = 0 });
    while (combat.phase == .command) combat.queue(.defend);
    combat.base_stats[1].speed = 1;
    combat.base_stats[2].speed = 9999;
    combat.acted = @splat(true);
    for (0..3) |i| combat.acted[i] = false;
    combat.phase = .resolving;
    combat.action_ticks = 400;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 0, .elapsed = 400, .cached = .{ .actor = 0 } };
    var tape = Tape{};
    var draws = tape.init();
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(u16, 1), combat.effectTicks());
    try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[0]);
    try std.testing.expectEqual(@as(@FieldType(battle.Effect, "kind"), .cast), combat.active.?.kind);
    var ticks: usize = 0;
    var saw_unite = false;
    var after_spell: u16 = 5000;
    while (combat.uniteBoundaryFor(1) != null and ticks < 1000) : (ticks += 1) {
        try combat.tickReplay(.{}, &draws);
        if (combat.active) |effect| {
            if (effect.kind == .cast and combat.enemy_hp[0] < 5000) after_spell = combat.enemy_hp[0];
            if (effect.kind == .unite) {
                saw_unite = true;
                try std.testing.expectEqual(@as(usize, 1), effect.actor);
                try std.testing.expect(effect.started_at > 400);
            }
        }
    }
    try std.testing.expect(ticks < 1000 and saw_unite);
    try std.testing.expectEqual(@as(u16, 4736), after_spell);
    try std.testing.expect(combat.enemy_hp[0] < after_spell);
    try std.testing.expectEqual(@as(u8, 2), combat.coordinator.?.dispatch_count);
}

test "Turtle skips only its own Unite recovery and its status RNG draw" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 1);
    combat.integration = .{ .host = host };
    combat.unbalanced[1] = 1;
    combat.runes[4] = combat.content.systems.?.runeIndex("turtle").?;
    try queueRound(&combat, .unite);
    combat.active = .{ .actor = 4, .target = combat.partyCount(), .kind = .unite, .unite_boundary = true };
    const values = [_]u15{100};
    var draws = rules.Draws{ .values = &values };
    combat.replay_draws = &draws;
    defer combat.replay_draws = null;
    combat.finishUnite();
    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[4]);
    try std.testing.expectEqual(@as(u8, 2), combat.unbalanced[5]);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
    try std.testing.expect(!combat.replay_exhausted);
}

test "integrated Phero uses source character types and agrees with all retained protection witnesses" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const world_data = try world_battle.load(allocator, world_battle.json);
    defer world_data.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const Case = struct { target: usize, hp: u16, dead_mask: u8, phero: bool, ids: [6][]const u8, protector: ?usize };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("../fixtures/world_protection.json"), .{});
    defer cases.deinit();
    for (cases.value) |row| {
        var view = content.value;
        view.protection = world_data.value.protection;
        view.initial_party = &row.ids;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        for (0..6) |index| {
            combat.progress.party[index].max_hp = 100;
            combat.progress.party[index].hp = if (index == row.target) row.hp else if (row.dead_mask & (@as(u8, 1) << @intCast(index)) != 0) 0 else 100;
            combat.departed[index] = row.dead_mask & (@as(u8, 1) << @intCast(index)) != 0;
            combat.runes[index] = null;
        }
        if (row.phero) for (view.systems.?.runes, 0..) |rune, index| if (std.mem.eql(u8, rune.id, "phero")) {
            combat.runes[row.target] = index;
            break;
        };
        if (row.phero) try std.testing.expect(std.mem.indexOf(u8, combat.runeHint(row.target), "protect") != null);
        const before = combat.random;
        try std.testing.expectEqual(row.protector, try combat.protector(row.target));
        try std.testing.expectEqualDeep(before, combat.random);
        if (row.phero and row.target == 3 and row.hp == 24 and row.dead_mask == 0 and std.mem.eql(u8, row.ids[2], "cleo")) {
            // A busy unrelated actor no longer blocks everyone; only the selected candidate's lock matters.
            combat.active = .{ .actor = 0, .target = 4, .kind = .attack };
            try std.testing.expectEqual(@as(?usize, 2), try combat.protector(3));
            combat.active.?.target = 2;
            try std.testing.expectEqual(@as(?usize, null), try combat.protector(3));
            combat.active = null;
            combat.content.protection = null;
            try std.testing.expectError(error.MissingProtectionCharacterType, combat.protector(3));
        }
    }
}

test "queued single-target items wait for knockout and skip an inactive recipient without spending" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    for ([_]field.items.Id{ .medicine, .mega_medicine, .antitoxin, .needle }) |id| {
        for ([_]bool{ false, true }) |departed| {
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
            combat.progress.party[0].inventory.slots[0] = .{ .id = id, .uses = id.maxUses() };
            const inventory = combat.progress.party[0].inventory;
            const random = combat.random;
            combat.actions[0] = .{ .item = .{ .id = id, .slot = 0, .target = 1 } };
            combat.phase = .resolving;
            combat.acted = @splat(true);
            combat.acted[0] = false;
            combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
            if (departed) {
                combat.departed[1] = true;
            } else {
                combat.progress.party[1].hp = 0;
                combat.markPartyKnockout(1);
                combat.advanceCoordinator();
                try std.testing.expectEqual(.dispatch, combat.coordinator.?.stage);
                try std.testing.expect(!combat.acted[0]);
                try std.testing.expect(combat.replay_unsupported == null);
                try std.testing.expect(combat.commitPartyKnockout(1));
                combat.active = .{ .actor = 2, .target = 3, .kind = .attack };
                combat.advanceCoordinator();
                try std.testing.expectEqual(.dispatch, combat.coordinator.?.stage);
                try std.testing.expect(!combat.acted[0]);
                combat.active = null;
            }
            combat.advanceCoordinator();
            try std.testing.expectEqual(.select, combat.coordinator.?.stage);
            try std.testing.expect(combat.coordinator.?.completed);
            try std.testing.expect(combat.acted[0]);
            try std.testing.expect(combat.replay_unsupported == null);
            try std.testing.expect(combat.medicine_action == null);
            try std.testing.expectEqualDeep(inventory, combat.progress.party[0].inventory);
            try std.testing.expectEqualDeep(random, combat.random);
            combat.enemy_hp = @splat(0);
            var tape = Tape{};
            var draws = tape.init();
            try tickToVictory(&combat, &draws, 300);
            try std.testing.expectEqualDeep(inventory, combat.progress.party[0].inventory);
        }
    }
}

test "two queued items wait for the first action and both complete" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const Case = struct { first: field.items.Id, second: field.items.Id };
    for ([_]Case{
        .{ .first = .medicine, .second = .medicine },
        .{ .first = .medicine, .second = .antitoxin },
        .{ .first = .medicine, .second = .dragon_seal_incense },
        .{ .first = .antitoxin, .second = .medicine },
        .{ .first = .needle, .second = .medicine },
        .{ .first = .dragon_seal_incense, .second = .medicine },
    }) |case| {
        const first = case.first;
        const second = case.second;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.progress.party[0].inventory.slots[0] = .{ .id = first, .uses = first.maxUses() };
        combat.progress.party[1].inventory.slots[0] = .{ .id = second, .uses = second.maxUses() };
        combat.progress.party[2].hp = 1;
        if (first == .antitoxin) combat.progress.party[2].status = .poisoned;
        combat.progress.party[3].hp = 1;
        combat.progress.party[3].status = .poisoned;
        combat.actions[0] = .{ .item = .{ .id = first, .slot = 0, .target = 2 } };
        combat.actions[1] = .{ .item = .{ .id = second, .slot = 0, .target = 3 } };
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.acted[1] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
        var tape = Tape{};
        var draws = tape.init();
        var waited = false;
        var started_second = false;
        for (0..400) |_| {
            const before = combat.medicine_action;
            const waiting = combat.coordinator != null and combat.coordinator.?.stage == .dispatch and combat.coordinator.?.current_actor == 1;
            const cursor = draws.cursor;
            try combat.tickReplay(.{}, &draws);
            if (waiting) try std.testing.expectEqual(cursor, draws.cursor);
            if (before) |item| if (item.actor == 0 and (!item.owner_released or !item.target_released)) {
                waited = true;
                try std.testing.expectEqual(second.maxUses(), combat.progress.party[1].inventory.slots[0].?.uses);
                try std.testing.expectEqual(@as(usize, 0), combat.medicine_action.?.actor);
            };
            if (combat.medicine_action) |item| if (item.actor == 1) {
                if (!started_second) {
                    try std.testing.expect(before.?.owner_released and before.?.target_released);
                    started_second = true;
                }
                if (item.owner_released and item.target_released) break;
            };
        }
        try std.testing.expect(waited and started_second);
        try std.testing.expect(combat.medicine_action.?.owner_released and combat.medicine_action.?.target_released);
        if (first == .antitoxin) try std.testing.expectEqual(.healthy, combat.progress.party[2].status) else if (first != .needle) try std.testing.expect(combat.progress.party[2].hp > 1);
        if (second == .antitoxin) try std.testing.expectEqual(.healthy, combat.progress.party[3].status) else try std.testing.expect(combat.progress.party[3].hp > 1);
        try std.testing.expectEqual(first.maxUses() -| 1, combat.progress.party[0].inventory.slots[0].?.uses);
        try std.testing.expectEqual(second.maxUses() -| 1, combat.progress.party[1].inventory.slots[0].?.uses);
    }
}

test "queued medicine waits for automatic revival before using its charge" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.progress.party[0].inventory.slots[0] = .{ .id = .medicine, .uses = 6 };
    combat.progress.party[1].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
    combat.actions[0] = .{ .item = .{ .id = .medicine, .slot = 0, .target = 1 } };
    combat.phase = .resolving;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
    combat.progress.party[1].hp = 0;
    combat.markPartyKnockout(1);
    try std.testing.expect(!combat.commitPartyKnockout(1));
    const release = combat.rules.automatic_revival.?.release_delay;
    for (0..release) |_| {
        combat.advanceCoordinator();
        try std.testing.expectEqual(.dispatch, combat.coordinator.?.stage);
        try std.testing.expectEqual(@as(u16, 6), combat.progress.party[0].inventory.slots[0].?.uses);
        try std.testing.expect(combat.replay_unsupported == null);
        combat.camera_ticks += 1;
        combat.advanceRevivals();
    }
    try std.testing.expect(combat.progress.party[1].hp > 0);
    combat.advanceCoordinator();
    try std.testing.expectEqual(.item_wait, combat.coordinator.?.stage);
    try std.testing.expectEqual(@as(u16, 5), combat.progress.party[0].inventory.slots[0].?.uses);
}

test "queued Incense uses the active group even if its stored target is down" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.progress.party[0].inventory.slots[0] = .{ .id = .dragon_seal_incense, .uses = 0 };
    const inventory = combat.progress.party[0].inventory;
    combat.progress.party[1].hp = 0;
    combat.progress.party[1].status = .unconscious;
    combat.actions[0] = .{ .item = .{ .id = .dragon_seal_incense, .slot = 0, .target = 1 } };
    combat.phase = .resolving;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
    combat.advanceCoordinator();
    try std.testing.expectEqual(.item_wait, combat.coordinator.?.stage);
    try std.testing.expect(combat.medicine_action.?.affects(0));
    try std.testing.expect(!combat.medicine_action.?.affects(1));
    try std.testing.expectEqualDeep(inventory, combat.progress.party[0].inventory);
}

test "Incense normal owners heal the active party once with protection and reusable inventory" {
    const world_data = try world_battle.load(allocator, world_battle.json);
    defer world_data.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var view = fixture.view;
    view.round_start = world_data.value.round_start;
    for (0..6) |owner| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, fixture.items.value, &members, 17);
        const ko = (owner + 4) % 6;
        const departed = (owner + 5) % 6;
        const protected = (owner + 1) % 6;
        const sleeping = (owner + 3) % 6;
        for (0..6) |index| {
            combat.progress.party[index].max_hp = 100;
            combat.progress.party[index].hp = if (index == ko) 0 else if (index == (owner + 2) % 6) 100 else if (index == sleeping) 99 else 1;
            combat.progress.party[index].status = if (index == ko) .unconscious else .healthy;
        }
        combat.departed[departed] = true;
        combat.protection[protected] = 2;
        combat.asleep[sleeping] = 2;
        combat.unbalanced[owner] = 1;
        combat.progress.party[owner].inventory.slots[0] = .{ .id = .dragon_seal_incense, .uses = 0 };
        combat.progress.party[owner].inventory.slots[1] = .{ .id = .medicine, .uses = 6 };
        const inventory = combat.progress.party[owner].inventory;
        var initial: [6]u16 = undefined;
        for (0..6) |index| initial[index] = combat.progress.party[index].hp;
        combat.actor = owner;
        combat.phase = .item;
        combat.selection = 0;
        var draws = rules.Draws{ .values = &.{} };
        try combat.tickReplay(.{ .confirm = true }, &draws);
        try std.testing.expect(combat.actions[owner].? == .item);
        try std.testing.expectEqual(owner, combat.actions[owner].?.item.target);
        combat.phase = .resolving;
        combat.round_start_pending = false;
        combat.acted = @splat(true);
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.medicine_action != null);
        const timing = combat.medicine_action.?.timing;
        try std.testing.expectEqual(timing.target_start + 65, timing.target_release);
        try std.testing.expect(!combat.medicine_action.?.affects(ko));
        try std.testing.expect(!combat.medicine_action.?.affects(departed));
        const first_tick = combat.medicine_action.?.ticks;
        for (@as(usize, first_tick) + 1..@as(usize, timing.target_release) + 1) |age| {
            try combat.tickReplay(.{}, &draws);
            errdefer std.debug.print("Incense owner={d} age={d}\n", .{ owner, age });
            try std.testing.expectEqual(age, combat.medicine_action.?.ticks);
            for (0..6) |index| {
                const eligible = index != ko and index != departed and index != protected;
                const expected: u16 = if (eligible and age >= timing.impact_tick) @min(100, initial[index] + 50) else initial[index];
                try std.testing.expectEqual(expected, combat.progress.party[index].hp);
                if (age >= timing.target_start and age < timing.target_release and index != ko and index != departed) try std.testing.expect(combat.coordinatorLocked(index));
            }
            try std.testing.expectEqualDeep(inventory, combat.progress.party[owner].inventory);
            try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        }
        try std.testing.expect(combat.medicine_action.?.target_released);
        try std.testing.expect(combat.medicine_action.?.owner_released);
        // The same tool remains usable for another action; interruption is local to one recipient.
        combat.medicine_action = null;
        combat.coordinator = null;
        combat.actions[owner] = .{ .item = .{ .slot = 0, .target = owner, .id = .dragon_seal_incense } };
        try std.testing.expect(combat.beginMedicine(owner));
        combat.medicine_action.?.interrupt(sleeping);
        try std.testing.expect(combat.medicine_action.?.interrupted(sleeping));
        try std.testing.expect(!combat.medicine_action.?.interrupted(owner));
        combat.progress.party[sleeping].hp = 1;
        for (0..combat.medicine_action.?.timing.target_release) |_| combat.advanceMedicine();
        try std.testing.expectEqual(@as(u16, 100), combat.progress.party[owner].hp);
        try std.testing.expectEqual(@as(u16, 1), combat.progress.party[sleeping].hp);
        try std.testing.expectEqual(@as(u16, 1), combat.progress.party[protected].hp);
        const finished = combat.medicine_action.?;
        for (0..5) |_| combat.advanceMedicine();
        try std.testing.expectEqualDeep(finished, combat.medicine_action.?);
        try std.testing.expectEqualDeep(inventory, combat.progress.party[owner].inventory);
    }
}

test "Incense feedback reports actual recovery when recipients change before impact" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    for (combat.progress.party) |*member| {
        member.max_hp = 100;
        member.hp = 1;
    }
    members[0].inventory.slots[0] = .{ .id = .dragon_seal_incense, .uses = 0 };
    combat.protection[4] = 2;
    combat.actions[0] = .{ .item = .{ .id = .dragon_seal_incense, .slot = 0, .target = 0 } };
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
    var draws = rules.Draws{ .values = &.{} };
    try combat.tickReplay(.{}, &draws);
    const timing = combat.medicine_action.?.timing;
    for (combat.medicine_action.?.ticks..timing.pending_tick) |_| try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual([6]u16{ 50, 50, 50, 50, 0, 50 }, combat.medicine_action.?.amounts);

    members[0].hp = 90;
    members[1].hp = 100;
    members[2].hp = 0;
    combat.markPartyKnockout(2);
    combat.departed[3] = true;
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(timing.impact_tick, combat.medicine_action.?.ticks);
    try std.testing.expectEqual([6]u16{ 10, 0, 0, 0, 0, 50 }, combat.medicine_action.?.amounts);
    try std.testing.expectEqual(@as(u16, 10), combat.medicine_action.?.amount);
    const expected_hp = [6]u16{ 100, 100, 0, 1, 1, 51 };
    for (combat.progress.party, expected_hp) |member, hp| try std.testing.expectEqual(hp, member.hp);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "Incense renders twelve frozen clones and restores white before its extra release wait" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/world_b_party_art.json", allocator, .limited(512 * 1024));
    defer allocator.free(bytes);
    const art = try battle.world_art.load(allocator, bytes);
    defer art.deinit();
    const view = fixture.view;
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(view, fixture.items.value, &members, 17);
    combat.content.world_art = art.value;
    combat.active = null;
    combat.progress.party[0].inventory.slots[0] = .{ .id = .dragon_seal_incense, .uses = 0 };
    combat.actions[0] = .{ .item = .{ .slot = 0, .target = 0, .id = .dragon_seal_incense } };
    try std.testing.expect(combat.beginMedicine(0));
    const timing = combat.medicine_action.?.timing;
    for (0..timing.target_start) |_| {
        combat.presentation_tick += 1;
        combat.advanceMedicine();
    }
    const item = combat.medicine_action.?;
    for (0..6) |index| {
        try std.testing.expect(item.particle_poses[index] != null);
        try std.testing.expect(item.particle_origins[index] != null);
    }
    combat.advanceMedicine();
    // Later actor changes must not move or reanimate the constructor's frozen copies.
    combat.presentation_tick += 111;
    var shifted = art.value;
    shifted.formation_slots[0].x += 100;
    combat.content.world_art = shifted;
    const frame = battle.world_art.compose(shifted, combat);
    const offsets = fixture.items.value.consumable(.dragon_seal_incense).?.battle.?.particles[0];
    var particles: usize = 0;
    var seen: [6]u8 = @splat(0);
    for (frame.quads[0..frame.length]) |quad| if (quad.medicine_particle) {
        particles += 1;
        try std.testing.expectEqualDeep([3]u8{ 64, 128, 0 }, quad.light);
        var matched = false;
        for (0..6) |index| for (offsets, 0..) |offset, side| {
            const origin = item.particle_origins[index].?;
            if (@abs(quad.position.x - (origin.x + offset[0])) < 0.001 and @abs(quad.position.y - (origin.y + offset[1])) < 0.001 and @abs(quad.position.z - (origin.z + offset[2])) < 0.001) {
                try std.testing.expectEqualDeep(shifted.actors[index].poses[item.particle_poses[index].?], quad.sprite);
                seen[index] |= @as(u8, 1) << @intCast(side);
                matched = true;
            }
        };
        try std.testing.expect(matched);
    };
    try std.testing.expectEqual(@as(usize, 12), particles);
    for (seen) |mask| try std.testing.expectEqual(@as(u8, 3), mask);
    combat.medicine_action.?.interrupt(2);
    const interrupted = battle.world_art.compose(shifted, combat);
    particles = 0;
    for (interrupted.quads[0..interrupted.length]) |quad| if (quad.medicine_particle) {
        particles += 1;
    };
    try std.testing.expectEqual(@as(usize, 10), particles);
    combat.medicine_action.?.ticks = timing.impact_tick + 31;
    const restored = battle.world_art.compose(shifted, combat);
    for (restored.quads[0..restored.length]) |quad| if (quad.actor != null and quad.actor.? < 6) try std.testing.expectEqualDeep([3]u8{ 128, 128, 128 }, quad.light);
    try std.testing.expect(!combat.medicine_action.?.target_released);
}

test "Roc source contact accepts sleep and protection without curing a surviving target" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const host = try hostFixture();
    defer host.deinit();
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    const art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_roc_art.json"));
    defer art.deinit();
    const encounter = for (source.value.encounters) |entry| {
        if (entry.enemies.len == 1 and std.mem.eql(u8, entry.enemies[0], "roc")) break entry;
    } else return error.MissingRocFixture;
    var encounters = [_]battle.Encounter{encounter};
    for (0..8) |scenario| {
        const mode = scenario % 4;
        const sleeping = mode != 1;
        const protected = mode == 1 or mode == 2;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        combat.content.enemies = source.value.enemies;
        combat.content.encounters = &encounters;
        combat.content.protection = source.value.protection;
        if (scenario >= 4) combat.content.world_art = art.value;
        combat.encounter = 0;
        combat.startEncounter();
        combat.active = null;
        combat.phase = .resolving;
        combat.acted = @splat(true);
        const owner = combat.partyCount();
        combat.acted[owner] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        combat.runes = @splat(null);
        combat.actions = @splat(null);
        for (1..combat.partyCount()) |member| {
            combat.progress.party[member].hp = 0;
            combat.progress.party[member].status = .unconscious;
        }
        combat.progress.party[0].max_hp = 1000;
        combat.progress.party[0].hp = if (mode == 3) 1 else 1000;
        combat.progress.party[0].status = if (mode == 2) .poisoned else .healthy;
        combat.asleep[0] = @intFromBool(sleeping);
        combat.protection[0] = if (protected) 2 else 0;
        const hp = combat.hp(0);
        var draws = rules.Draws{ .values = &.{ 51, 0, 51 } };
        var contact = false;
        var returned = false;
        var rollback = false;
        for (0..180) |_| {
            if (combat.active != null and combat.active.?.kind == .attack and combat.effectTicks() + 1 == combat.enemy(0).ordinary_timing.?.impact_tick) {
                const before_hp = combat.hp(0);
                const before_status = combat.progress.party[0].status;
                var refused = combat;
                var short = rules.Draws{ .values = &.{} };
                try std.testing.expectError(error.RandomInputExhausted, refused.tickReplay(.{}, &short));
                try std.testing.expectEqual(before_hp, refused.hp(0));
                try std.testing.expectEqual(before_status, refused.progress.party[0].status);
                try std.testing.expectEqualDeep(combat.asleep, refused.asleep);
                try std.testing.expectEqualDeep(combat.protection, refused.protection);
                try std.testing.expectEqualDeep(combat.active, refused.active);
                try std.testing.expectEqual(@as(usize, 0), short.cursor);
                rollback = true;
            }
            try combat.tickReplay(.{}, &draws);
            if (!contact and draws.cursor == 3) {
                contact = true;
                try std.testing.expectEqual(combat.enemy(0).ordinary_timing.?.impact_tick, combat.effectTicks());
                if (protected) try std.testing.expectEqual(hp, combat.hp(0)) else try std.testing.expect(combat.hp(0) < hp);
                try std.testing.expectEqual(@as(u8, @intFromBool(sleeping)), combat.asleep[0]);
            }
            if (contact and mode != 3) {
                try std.testing.expectEqual(@as(u8, @intFromBool(sleeping)), combat.asleep[0]);
                if (mode == 2) try std.testing.expectEqual(field.game_state.Status.poisoned, combat.progress.party[0].status);
            }
            if (contact and combat.active == null) {
                returned = true;
                break;
            }
        }
        try std.testing.expect(contact and returned and rollback);
        try std.testing.expectEqual(@as(usize, 3), draws.cursor);
        if (mode == 3) {
            try std.testing.expectEqual(@as(u16, 0), combat.hp(0));
            try std.testing.expectEqual(@as(u8, 0), combat.asleep[0]);
            try std.testing.expectEqual(field.game_state.Status.unconscious, combat.progress.party[0].status);
        }
    }
}
