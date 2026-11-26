const characterFields = @import("character_fields.zig").capture;
const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const demo = @import("demo_batch");
const allocator = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
fn resolve(session: *demo.Session) !void {
    if (session.battle.phase == .confirm_round) session.tick(.{ .confirm = true });
    for (0..10000) |_| {
        try session.battle.progress.validate();
        if (session.battle.phase != .resolving) return;
        session.tick(.{});
    }
    return error.RoundDidNotFinish;
}
fn choose(state: *battle.State, command: @import("game").Command) !void {
    if (state.phase == .battle_menu) state.tick(.{ .confirm = true });
    for (0..5) |_| {
        if (state.picker.selected == command) {
            state.tick(.{ .confirm = true });
            return;
        }
        state.tick(.{ .down = true });
    }
    return error.CommandUnavailable;
}

test "twelve demos finish through the shared resolver across twenty seeds" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for (0..20) |seed| {
        var members: [6]battle.Member = undefined;
        var session = try demo.Session.init(content.value, rules.value, &members);
        for (0..12) |index| {
            session.start(index);
            session.battle.random = .init(seed);
            if (index == 1) try session.battle.swapFormation(0, 3);
            if (index == 2) session.transfer();
            if (index == 3) session.cycleEquipment(false);
            session.screen = .fight;
            if (index == 10) {
                session.battle.escape_allowed = false;
                session.tick(.{ .down = true });
                session.tick(.{ .confirm = true });
                try equal(.run_refused, session.battle.phase);
                session.tick(.{ .confirm = true });
                try equal(.resolving, session.battle.phase);
                session.defeatSetup();
                for (0..30) |_| {
                    session.suggested();
                    try resolve(&session);
                    if (session.battle.phase == .defeat) break;
                }
                try equal(.defeat, session.battle.phase);
                session.tick(.{ .confirm = true });
                session.battle.escape_allowed = true;
                for (0..30) |_| {
                    session.tick(.{ .down = true });
                    session.tick(.{ .confirm = true });
                    try resolve(&session);
                    if (session.battle.phase == .escaped) break;
                }
                try equal(.escaped, session.battle.phase);
                try equal(@as(u32, 350), session.battle.progress.money);
                session.tick(.{ .confirm = true });
            } else {
                for (0..100) |_| {
                    if (session.screen == .result) break;
                    if (session.battle.phase == .victory) {
                        const money = session.battle.progress.money;
                        const exp = characterFields("experience", session.battle.progress.party);
                        for (0..20) |_| session.tick(.{});
                        try equal(money, session.battle.progress.money);
                        try std.testing.expectEqualDeep(exp, characterFields("experience", session.battle.progress.party));
                        session.tick(.{ .confirm = true });
                    } else {
                        try equal(.battle_menu, session.battle.phase);
                        session.suggested();
                        try resolve(&session);
                    }
                }
            }
            try equal(.result, session.screen);
            try expect(session.completed[index]);
            if (index == 9) {
                try equal(@as(u8, 6), session.battle.progress.party[0].level);
                try expect(session.battle.drop_received);
                for (0..6) |i| {
                    try equal(@as(u32, 100), session.battle.award_exp[i]);
                    try equal(@as(u32, if (i == 0) 50 else 100), session.battle.progress.party[i].experience);
                    try equal(@as(u8, if (i == 0) 6 else 5), session.battle.progress.party[i].level);
                    try equal(@as(u8, 5), session.battle.reward_levels[i]);
                }
            }
            if (index == 11) try equal(@as(usize, 8), session.battle.encounter);
        }
    }
}

test "formation, inventory and equipment preserve identity and reject invalid changes atomically" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(1);
    const original = members;
    try session.battle.swapFormation(0, 3);
    try equal(@as(usize, 3), session.battle.formationSlot(0));
    try std.testing.expectEqualDeep(original, members);
    session.start(2);
    session.recipient = 5;
    const before = members;
    try std.testing.expectError(error.InventoryFull, session.battle.progress.transfer(0, 0, 5));
    try std.testing.expectEqualDeep(before, members);
    session.recipient = 1;
    session.transfer();
    try equal(@as(u16, 2), members[1].inventory.slots[2].?.uses);
    try equal(@as(usize, 1), members[0].inventory.count());
    session.discard(false);
    session.discard(false);
    try equal(@as(usize, 1), members[0].inventory.count());
    session.discard(false);
    session.discard(true);
    try equal(@as(usize, 0), members[0].inventory.count());
    session.start(3);
    const defense = session.battle.stats(0).defense;
    try session.battle.equip(0, 1);
    try equal(defense + 2, session.battle.stats(0).defense);
    try session.battle.equip(0, null);
    try equal(defense, session.battle.stats(0).defense);
    try std.testing.expectError(error.InvalidEquipment, session.battle.equip(0, 99));
}

test "runes select exact targets, group once, reject full health and revive without a queued turn" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(4);
    try choose(&session.battle, .rune);
    session.tick(.{ .confirm = true });
    session.tick(.{ .down = true });
    session.tick(.{ .down = true });
    session.tick(.{ .confirm = true });
    try equal(@as(usize, 2), session.battle.actions[0].?.spell.target);
    for (1..6) |_| session.battle.queue(.defend);
    session.tick(.{ .confirm = true });
    for (0..2000) |_| {
        if (session.battle.active) |effect| if (effect.kind == .cast and session.battle.action_ticks == session.battle.impactTick() + 1) break;
        session.tick(.{});
    }
    try equal(@as(u16, 18), session.battle.enemy_hp[0]);
    try equal(@as(u16, 18), session.battle.enemy_hp[1]);
    try equal(@as(u16, 0), session.battle.enemy_hp[2]);
    try equal(@as(u16, 3), members[0].rune_charges[0]);
    session.start(5);
    session.suggested();
    try resolve(&session);
    for (session.battle.enemy_hp[0..3]) |hp| try equal(@as(u16, 0), hp);
    try equal(@as(u16, 1), members[0].rune_charges[1]);
    session.start(6);
    session.suggested();
    try resolve(&session);
    try expect(members[0].hp > 20);
    try expect(members[2].hp > 0);
    try equal(.healthy, members[2].status);
    try equal(.healthy, members[1].status);
    try equal(@as(u16, 2), members[1].rune_charges[3]);
    session.start(6);
    members[0].hp = members[0].max_hp;
    session.battle.actions = @splat(.defend);
    session.battle.actions[0] = .{ .spell = .{ .index = 2, .target = 0 } };
    session.battle.phase = .resolving;
    session.battle.progress.party[0].base_stats.speed = 999;
    try resolve(&session);
    try equal(@as(u16, 5), members[0].rune_charges[0]);
}

test "unite reserves both actors, backs out cleanly and becomes unavailable after partner KO" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(8);
    session.battle.queue(.defend);
    try expect(session.battle.canUnite(1));
    try choose(&session.battle, .unite);
    session.tick(.{ .down = true });
    session.tick(.{ .down = true });
    session.tick(.{ .confirm = true });
    try equal(@as(usize, 3), session.battle.actor);
    try equal(@as(usize, 1), session.battle.actions[2].?.assist);
    session.tick(.{ .cancel = true });
    try equal(@as(usize, 1), session.battle.actor);
    try expect(session.battle.actions[2] == null);
    session.start(8);
    session.suggested();
    members[2].hp = 0;
    members[2].status = .unconscious;
    try resolve(&session);
    try equal(@as(u16, 18), session.battle.enemy_hp[2]);
}

test "sleep skips actions, physical attacks wake and poison is curable" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(7);
    session.suggested();
    try resolve(&session);
    try equal(@as(u8, 2), session.battle.actor_conditions[6].sleep_turns);
    try equal(@as(u16, 114), members[1].hp);
    session.suggested();
    try resolve(&session);
    try equal(.healthy, members[1].status);
    try equal(@as(u8, 1), session.battle.actor_conditions[6].sleep_turns);
    session.battle.actions = @splat(.defend);
    session.battle.actions[0] = .{ .attack = 0 };
    session.battle.progress.party[0].base_stats.skill = 999;
    session.battle.phase = .confirm_round;
    try resolve(&session);
    try equal(@as(u8, 0), session.battle.actor_conditions[6].sleep_turns);
}

test "demo checkpoint round trips separately and rejects corrupt state before mutation" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(11);
    members[0].hp = 54;
    session.battle.actor_conditions[3].sleep_turns = 2;
    session.battle.actor_conditions[session.battle.partyCount()].sleep_turns = 4;
    session.battle.progress.party[0].rune = content.value.systems.?.runeIndex("fire").?;
    try session.battle.swapFormation(0, 5);
    try session.battle.equip(0, 1);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try demo.save(std.testing.io, allocator, temporary.dir, session);
    const before = try demo.Snapshot.capture(session);
    try std.testing.expectEqual([12]u8{ 0, 0, 0, 2, 0, 0, 4, 0, 0, 0, 0, 0 }, before.asleep);
    session.start(0);
    var profiles: [6]battle.Profile = undefined;
    @memcpy(&profiles, content.value.party);
    std.mem.reverse(battle.Profile, &profiles);
    session.battle.content.party = &profiles;
    try demo.load(std.testing.io, allocator, temporary.dir, &session);
    try std.testing.expectEqual(@as(u8, 2), session.battle.actor_conditions[3].sleep_turns);
    try std.testing.expectEqual(@as(u8, 4), session.battle.actor_conditions[session.battle.partyCount()].sleep_turns);
    const after = try demo.Snapshot.capture(session);
    try std.testing.expectEqualDeep(before, after);
    for (members, 0..) |member, i| try std.testing.expectEqualStrings(member.id, session.battle.partyProfile(i).id);
    var bad = before;
    bad.schema = "suikoden-demo-save/1";
    try std.testing.expectError(error.InvalidDemoSave, bad.restore(&session));
    bad = before;
    bad.runes[0] = 999;
    try std.testing.expectError(error.InvalidDemoSave, bad.restore(&session));
    bad = before;
    bad.party[0].max_rune_charges[3] = 9;
    try std.testing.expectError(error.InvalidDemoSave, bad.restore(&session));
    bad = before;
    bad.formation[1] = bad.formation[0];
    try std.testing.expectError(error.InvalidDemoSave, bad.restore(&session));
    bad = before;
    bad.asleep[3] = 11;
    try std.testing.expectError(error.InvalidDemoSave, bad.restore(&session));
    try std.testing.expectEqualDeep(before, try demo.Snapshot.capture(session));
    session.battle.queue(.defend);
    try std.testing.expectError(error.SaveAtRoundStart, demo.save(std.testing.io, allocator, temporary.dir, session));
    session.start(11);
    try demo.load(std.testing.io, allocator, temporary.dir, &session);
    try std.testing.expectEqualDeep(before, try demo.Snapshot.capture(session));
}

test "runes belong to their hero, native Magic thresholds control all four tiers, and casts commit at impact" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const native = try std.json.parseFromSlice([]const [4]u16, allocator, @embedFile("fixtures/magic_capacity.json"), .{});
    defer native.deinit();
    for (native.value, 0..) |expected, magic| try std.testing.expectEqualDeep(expected, content.value.systems.?.magicCapacity(@intCast(magic)));
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(0);
    for (0..6) |i| try expect(!session.battle.hasMagic(i));
    try std.testing.expectEqualStrings("Boar Rune", session.battle.rune(2).?.name);
    session.start(4);
    try expect(session.battle.canCast(0, 0));
    try expect(!session.battle.canCast(1, 0));
    try expect(!session.battle.canCast(0, 2));
    session.battle.queue(.{ .spell = .{ .index = 2, .target = 0 } });
    try equal(@as(usize, 0), session.battle.actor);
    try expect(session.battle.actions[0] == null);
    session.battle.progress.party[0].base_stats.magic = 40;
    session.battle.refillMagic(0);
    try expect(!session.battle.canCast(0, 1));
    session.battle.progress.party[0].base_stats.magic = 41;
    session.battle.refillMagic(0);
    try expect(session.battle.canCast(0, 1));
    session.battle.progress.party[0].rune = content.value.systems.?.runeIndex("rage").?;
    try equal(@as(?u2, 0), session.battle.spellTier(0, 1));
    session.battle.progress.party[0].rune = content.value.systems.?.runeIndex("fire").?;
    try equal(@as(?u2, 1), session.battle.spellTier(0, 1));
    session.start(4);
    session.suggested();
    session.battle.progress.party[5].base_stats.speed = 999;
    session.tick(.{ .confirm = true });
    session.tick(.{});
    try equal(@as(usize, 5), session.battle.active.?.actor);
    try equal(.defend, session.battle.active.?.kind);
    for (0..2000) |_| {
        if (session.battle.active) |effect| if (effect.kind == .cast) break;
        session.tick(.{});
    }
    try equal(.cast, session.battle.active.?.kind);
    const before = session.battle.enemy_hp;
    const charges = members[0].rune_charges;
    while (session.battle.action_ticks < session.battle.impactTick()) {
        try equal(before, session.battle.enemy_hp);
        try equal(charges, members[0].rune_charges);
        session.tick(.{});
    }
    try equal(@as(u16, 0), session.battle.enemy_hp[2]);
    try equal(charges[0] - 1, members[0].rune_charges[0]);
    for (0..20) |_| session.tick(.{});
    try equal(charges[0] - 1, members[0].rune_charges[0]);
    // An action injected after selection still cannot cast another rune's spell.
    session.start(4);
    session.battle.actions = @splat(.defend);
    session.battle.actions[1] = .{ .spell = .{ .index = 0, .target = 0 } };
    session.battle.phase = .resolving;
    const gremio_charges = members[1].rune_charges;
    try resolve(&session);
    try equal(@as(u16, 18), session.battle.enemy_hp[0]);
    try equal(gremio_charges, members[1].rune_charges);
    session.start(4);
    session.suggested();
    session.battle.enemy_hp[2] = 0;
    session.tick(.{ .confirm = true });
    for (0..2000) |_| {
        if (session.battle.active) |effect| if (effect.kind == .cast) {
            try equal(@as(usize, 6), effect.target);
            try equal(@as(?usize, 8), effect.retargeted_from);
            break;
        };
        session.tick(.{});
    }
    try equal(.cast, session.battle.active.?.kind);
    try resolve(&session);
    try equal(@as(u16, 0), session.battle.enemy_hp[0]);
    try equal(@as(u16, 18), session.battle.enemy_hp[1]);
    try equal(@as(u16, 3), members[0].rune_charges[0]);
}

test "progression agrees with complete native level-up and EXP award routines" {
    const Growth = struct { member: usize, level: u8, randoms: [7]u15, new_level: u8, stats: [6]u16, max_hp: u16, hp: u16 };
    const Award = struct { encounter: usize, levels: [6]u8, expected: [6]u32 };
    const Vectors = struct { growth: []const Growth, awards: []const Award };
    const vectors = try std.json.parseFromSlice(Vectors, allocator, @embedFile("fixtures/demo_progression.json"), .{});
    defer vectors.deinit();
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    for (vectors.value.growth) |row| {
        session.start(0);
        session.battle.progress.party[row.member].level = row.level;
        members[row.member].hp -= 20;
        session.battle.levelUp(row.member, row.randoms);
        const stats = session.battle.stats(row.member);
        try equal(row.new_level, session.battle.progress.party[row.member].level);
        try equal(row.max_hp, members[row.member].max_hp);
        try equal(row.hp, members[row.member].hp);
        try std.testing.expectEqualSlices(u16, &row.stats, &.{ stats.attack, stats.skill, stats.defense, stats.speed, stats.magic, stats.luck });
    }
    for (vectors.value.awards) |row| {
        session.start(11);
        session.battle.encounter = row.encounter;
        for (session.battle.progress.party, row.levels) |*member, level| member.level = level;
        for (0..6) |i| try equal(row.expected[i], session.battle.experienceAward(i));
    }
}

test "six-member Gremio target remains BonBon three while Hero defends" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for (0..20) |seed| {
        var members: [6]battle.Member = undefined;
        var session = try demo.Session.init(content.value, rules.value, &members);
        session.start(0);
        session.battle.random = .init(seed);
        session.battle.queue(.defend);
        try choose(&session.battle, .attack);
        session.tick(.{ .down = true });
        session.tick(.{ .down = true });
        session.tick(.{ .confirm = true });
        for (2..6) |_| session.battle.queue(.defend);
        session.tick(.{ .confirm = true });
        var seen = false;
        for (0..3000) |_| {
            if (session.battle.active) |effect| if (effect.actor == 1) {
                try equal(@as(usize, 8), effect.target);
                try expect(effect.retargeted_from == null);
                seen = true;
            };
            if (session.battle.phase != .resolving) break;
            session.tick(.{});
        }
        try expect(seen);
        try equal(@as(u16, 18), session.battle.enemy_hp[0]);
        try equal(@as(u16, 18), session.battle.enemy_hp[1]);
    }
}

test "generic valid content with missing scenario inputs is rejected before presets can index it" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    var invalid = content.value;
    invalid.systems.?.spells = invalid.systems.?.spells[0..1];
    try std.testing.expectError(error.InvalidRune, invalid.validate());
    invalid = content.value;
    var party = content.value.party[0..6].*;
    party[3].weapon_range = null;
    invalid.party = &party;
    try std.testing.expectError(error.MissingWeaponRange, invalid.validate());
    invalid = content.value;
    var encounters = content.value.encounters[0..9].*;
    encounters[1].enemy_rows = null;
    invalid.encounters = &encounters;
    try std.testing.expectError(error.MissingEnemyRows, invalid.validate());
    encounters[1].enemy_rows = &.{.front};
    try std.testing.expectError(error.InvalidEncounter, invalid.validate());
    invalid.schema = "suikoden-battle-trial/3";
    try std.testing.expectError(error.UnsupportedBattleSchema, invalid.validate());
}

test "weapon reach agrees with the complete original target builder across 108 cases" {
    const Vector = struct { weapon_range: battle.WeaponRange, slot: usize, enemy_rows: []const battle.Row, expected: []const bool };
    const vectors = try std.json.parseFromSlice([]const Vector, allocator, @embedFile("fixtures/battle_range.json"), .{});
    defer vectors.deinit();
    try equal(@as(usize, 108), vectors.value.len);
    for (vectors.value) |row| {
        for (row.enemy_rows, row.expected) |target, expected| {
            try equal(expected, row.weapon_range.reaches(if (row.slot < 3) .front else .back, target));
        }
    }
}

test "Viktor's back-row short weapon disables Attack in manual and suggested commands" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(1);
    session.screen = .fight;
    for (0..3) |_| session.battle.queue(.defend);
    try equal(@as(usize, 3), session.battle.actor);
    try equal(battle.Row.back, session.battle.partyRow(3));
    try expect(!session.battle.picker.enabled[0]);
    try equal(@import("game").Command.defend, session.battle.picker.selected);
    try expect(session.battle.picker.enabled[1] and !session.battle.picker.enabled[2] and session.battle.picker.enabled[3]);
    session.battle.queue(.{ .attack = 0 });
    try expect(session.battle.actions[3] == null);
    session.suggested();
    try expect(session.battle.actions[3].? == .defend);
    for (session.battle.actions[0..6], 0..) |action, member| if (action.? == .attack) {
        try expect(session.battle.canAttackTarget(member, action.?.attack));
    };
    session.start(1);
    session.screen = .fight;
    for (0..3) |_| session.battle.queue(.defend);
    const identity = members[3];
    try session.battle.swapFormation(0, 3);
    try std.testing.expectEqualDeep(identity, members[3]);
    try equal(battle.Row.front, session.battle.partyRow(3));
    try expect(session.battle.picker.enabled[0]);
    try expect(session.battle.canAttackTarget(3, 0));
    try expect(session.battle.canAttackTarget(0, 0)); // Hero's medium weapon still reaches from the back.
    session.tick(.{ .confirm = true });
    try equal(.target, session.battle.phase);
    session.tick(.{ .confirm = true });
    try equal(@as(usize, 0), session.battle.actions[3].?.attack);
}

test "queued attacks recheck reach after formation changes without damaging an unreachable enemy" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(0);
    try session.battle.swapFormation(0, 3);
    session.battle.actions = @splat(.defend);
    session.battle.actions[3] = .{ .attack = 0 };
    session.battle.phase = .confirm_round;
    session.tick(.{ .confirm = true });
    try session.battle.swapFormation(0, 3);
    var blocked = false;
    for (0..5000) |_| {
        if (session.battle.active) |effect| if (effect.actor == 3) {
            try equal(.unavailable, effect.kind);
            blocked = true;
        };
        if (session.battle.phase != .resolving) break;
        session.tick(.{});
    }
    try expect(blocked);
    try std.testing.expectEqualSlices(u16, &.{ 18, 18, 18 }, session.battle.enemy_hp[0..3]);
}

test "medium attacks skip enemy back rows and cannot retarget there after the front target falls" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(0);
    var encounters = content.value.encounters[0..9].*;
    encounters[1].enemy_rows = &.{ .back, .front, .back };
    session.battle.content.encounters = &encounters;
    session.battle.choose(0);
    try choose(&session.battle, .attack);
    try equal(@as(usize, 1), session.battle.selection);
    session.tick(.{ .down = true });
    try equal(@as(usize, 1), session.battle.selection);
    session.battle.actions = @splat(.defend);
    session.battle.actions[0] = .{ .attack = 1 };
    session.battle.phase = .confirm_round;
    session.tick(.{ .confirm = true });
    session.battle.enemy_hp[1] = 0;
    try resolve(&session);
    try std.testing.expectEqualSlices(u16, &.{ 18, 0, 18 }, session.battle.enemy_hp[0..3]);
    session.battle.choose(0);
    try expect(!session.battle.picker.enabled[0]);
}

test "checkpoint restores attack availability from saved formation and first living member" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(11);
    for (members[0..3]) |*member| {
        member.hp = 0;
        member.status = .unconscious;
    }
    try session.battle.swapFormation(0, 3);
    session.battle.choose(3);
    const snapshot = try demo.Snapshot.capture(session);
    session.start(0);
    try snapshot.restore(&session);
    try equal(@as(usize, 3), session.battle.actor);
    try equal(battle.Row.front, session.battle.partyRow(3));
    try expect(session.battle.picker.enabled[0]);
    try equal(.battle_menu, session.battle.phase);
    session.tick(.{ .confirm = true });
    session.tick(.{ .confirm = true });
    try equal(.target, session.battle.phase);
}

test "battle menu Fight, Run and Let go agree with original decisions and backtracking" {
    const Vector = struct { party_levels: []const u8, enemy_levels: []const u8, allowed: bool, roll: u15, let_go: bool, success: bool };
    const vectors = try std.json.parseFromSlice([]const Vector, allocator, @embedFile("fixtures/battle_exit.json"), .{});
    defer vectors.deinit();
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    for (vectors.value) |row| {
        session.start(0);
        var enemies: [3]battle.Profile = @splat(content.value.enemies[0]);
        const ids = [_][]const u8{ "one", "two", "three" };
        for (row.enemy_levels, 0..) |level, i| {
            enemies[i].id = ids[i];
            enemies[i].level = level;
        }
        var encounters = content.value.encounters[0..9].*;
        encounters[1].enemies = ids[0..row.enemy_levels.len];
        session.battle.content.encounters = &encounters;
        session.battle.content.enemies = enemies[0..row.enemy_levels.len];
        session.battle.progress.party = members[0..row.party_levels.len];
        for (session.battle.progress.party[0..row.party_levels.len], row.party_levels) |*member, level| member.level = level;
        session.battle.escape_allowed = row.allowed;
        try equal(row.let_go, session.battle.canLetGo());
        try equal(row.success, session.battle.runSucceeds(row.roll));
        if (row.roll == 0) {
            for (0..100) |roll| {
                const expected = row.allowed and (row.let_go or roll >= 51);
                try equal(expected, session.battle.runSucceeds(@intCast(roll)));
                try equal(expected, session.battle.runSucceeds(@intCast(roll + 100)));
            }
        }
        session.battle.progress.party = &members;
        session.battle.content = content.value;
    }
    var successes: usize = 0;
    var failures: usize = 0;
    for (0..20) |seed| {
        session.start(0);
        for (session.battle.progress.party) |*member| member.level = 1;
        session.battle.random = .init(seed);
        var expected_random = session.battle.random;
        const succeeds = expected_random.random().int(u15) % 100 >= 51;
        try expect(!session.battle.canLetGo());
        session.tick(.{ .down = true });
        session.tick(.{ .confirm = true });
        try equal(.resolving, session.battle.phase);
        for (session.battle.actions[0..session.battle.partyCount()]) |action| try equal(.defend, action.?);
        for (0..100) |_| {
            if (session.battle.phase == .escaped or (session.battle.active != null and session.battle.active.?.kind == .escape_failed)) break;
            session.tick(.{});
        }
        if (succeeds) {
            try equal(.escaped, session.battle.phase);
            successes += 1;
        } else {
            try equal(.resolving, session.battle.phase);
            try equal(.escape_failed, session.battle.active.?.kind);
            failures += 1;
        }
        try expect(!session.battle.released_enemies);
    }
    try expect(successes > 0 and failures > 0);
    session.start(0);
    try equal(.battle_menu, session.battle.phase);
    session.tick(.{ .confirm = true });
    try equal(.command, session.battle.phase);
    session.battle.queue(.defend);
    session.tick(.{ .cancel = true });
    try equal(@as(usize, 0), session.battle.actor);
    session.tick(.{ .cancel = true });
    try equal(.battle_menu, session.battle.phase);
    for (session.battle.actions) |action| try expect(action == null);
    session.tick(.{ .down = true });
    session.tick(.{ .confirm = true });
    try equal(.escaped, session.battle.phase);
    try expect(session.battle.released_enemies);
    try equal(@as(u32, 350), session.battle.progress.money);
    try equal(@as([6]u32, @splat(0)), characterFields("experience", session.battle.progress.party));
    session.start(10);
    var encounters = content.value.encounters[0..9].*;
    encounters[2].escape_allowed = false;
    session.battle.content.encounters = &encounters;
    try expect(!session.battle.canEscape());
    const blocked_random = session.battle.random;
    session.tick(.{ .down = true });
    session.tick(.{ .confirm = true });
    try equal(.run_refused, session.battle.phase);
    for (session.battle.actions[0..session.battle.partyCount()]) |action| try equal(.defend, action.?);
    session.tick(.{});
    try equal(.run_refused, session.battle.phase);
    session.tick(.{ .confirm = true });
    try equal(.resolving, session.battle.phase);
    try std.testing.expectEqualDeep(blocked_random, session.battle.random);
    session.battle.content = content.value;
    session.start(0);
    for (0..3) |_| session.tick(.{ .down = true });
    session.tick(.{ .confirm = true });
    try equal(.resolving, session.battle.phase);
    for (session.battle.actions[0..6], 0..) |action, i| {
        if (action.? == .attack) try expect(session.battle.canAttackTarget(i, action.?.attack));
    }
    try resolve(&session);
}

test "Bribe consumes retained decisions through the root menu without random draws" {
    const Vector = struct { raw_money: u32, cost: u32, money: u32, allowed: bool, success: bool, remaining_money: u32 };
    const vectors = try std.json.parseFromSlice([]const Vector, allocator, @embedFile("fixtures/battle_bribe.json"), .{});
    defer vectors.deinit();
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    for (vectors.value) |row| {
        session.start(0);
        var encounters = content.value.encounters[0..9].*;
        encounters[session.battle.encounter].bribe_cost = row.cost;
        encounters[session.battle.encounter].escape_allowed = row.allowed;
        session.battle.content.encounters = &encounters;
        session.battle.progress.money = row.money;
        const random_before = session.battle.random;
        session.battle.tick(.{ .down = true });
        session.battle.tick(.{ .down = true });
        session.battle.tick(.{ .confirm = true });
        try equal(if (row.success) battle.Phase.escaped else .bribe_refused, session.battle.phase);
        try equal(row.remaining_money, session.battle.progress.money);
        try equal(row.success, session.battle.bribed_enemies);
        try expect(!session.battle.released_enemies);
        for (session.battle.actions[0..session.battle.partyCount()]) |action| try equal(.defend, action.?);
        try std.testing.expectEqualDeep(random_before, session.battle.random);
        try equal(@as([6]u32, @splat(0)), characterFields("experience", session.battle.progress.party));
        session.battle.tick(.{ .confirm = true });
        try equal(if (row.success) battle.Phase.complete else .resolving, session.battle.phase);
        try equal(row.remaining_money, session.battle.progress.money);
        try std.testing.expectEqualDeep(random_before, session.battle.random);
        session.battle.content = content.value;
    }
}

test "Talisman synchronizes both participants, commits once to its chosen enemy and uses both turns" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    for ([_]usize{ 1, 2 }) |initiator| {
        session.start(8);
        const partner: usize = if (initiator == 1) 2 else 1;
        session.battle.actions = @splat(.defend);
        session.battle.actions[partner] = null;
        session.battle.choose(initiator);
        session.battle.queue(.{ .unite = 2 });
        try equal(@as(usize, initiator), session.battle.actions[partner].?.assist);
        for (&session.battle.actions) |*action| if (action.* == null) {
            action.* = .defend;
        };
        session.battle.progress.party[initiator].base_stats.speed = 999;
        session.battle.phase = .resolving;
        session.tick(.{});
        const effect = session.battle.active.?;
        try equal(.unite, effect.kind);
        try equal(@as(?usize, partner), effect.partner);
        try equal(@as(usize, 8), effect.target);
        try expect(session.battle.isActing(initiator) and session.battle.isActing(partner));
        try expect(session.battle.acted[initiator] and session.battle.acted[partner]);
        const impact = session.battle.impactTick();
        session.battle.action_ticks = impact - 1;
        session.tick(.{});
        for ([_]usize{ initiator, partner }) |member| {
            try equal(content.value.party[member].motion.?.impact_tick, session.battle.animationTick(member));
        }
        try equal(@as(u16, 0), session.battle.enemy_hp[2]);
        try equal(@as(u16, 18), session.battle.enemy_hp[0]);
        try equal(@as(u16, 18), session.battle.enemy_hp[1]);
        const after = session.battle.enemy_hp;
        while (session.battle.active != null) session.tick(.{});
        try equal(after, session.battle.enemy_hp);
        while (session.battle.phase == .resolving) {
            session.tick(.{});
            if (session.battle.active) |next| try expect(next.actor != initiator and next.actor != partner);
        }
    }
    for ([_]bool{ false, true }) |sleep| {
        session.start(8);
        session.suggested();
        session.battle.progress.party[1].base_stats.speed = 999;
        session.tick(.{ .confirm = true });
        session.tick(.{});
        try equal(.unite, session.battle.active.?.kind);
        if (sleep) session.battle.actor_conditions[2].sleep_turns = 1 else {
            members[2].hp = 0;
            members[2].status = .unconscious;
        }
        session.battle.action_ticks = session.battle.impactTick() - 1;
        session.tick(.{});
        try equal(.unavailable, session.battle.active.?.kind);
        try equal(@as(u16, 18), session.battle.enemy_hp[2]);
    }
}

test "rewards credit every survivor once, record level changes and exclude KO members" {
    const content = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var session = try demo.Session.init(content.value, rules.value, &members);
    session.start(9);
    members[3].hp = 0;
    members[3].status = .unconscious;
    for (0..6) |i| session.battle.progress.party[i].experience = 950;
    const expected = session.battle.experienceAward(0);
    session.suggested();
    for (0..20) |_| {
        try resolve(&session);
        if (session.battle.phase == .victory) break;
        session.suggested();
    }
    try equal(.victory, session.battle.phase);
    for (0..6) |i| {
        try equal(@as(u32, if (i == 3) 0 else expected), session.battle.award_exp[i]);
        try equal(@as(u8, if (i == 3) 5 else 6), session.battle.progress.party[i].level);
        try equal(@as(u8, 5), session.battle.reward_levels[i]);
        try equal(@as(u32, if (i == 3) 950 else 950 + expected - 1000), session.battle.progress.party[i].experience);
    }
    const levels = characterFields("level", session.battle.progress.party);
    const experience = characterFields("experience", session.battle.progress.party);
    const money = session.battle.progress.money;
    for (0..100) |_| session.tick(.{});
    try equal(levels, characterFields("level", session.battle.progress.party));
    try equal(experience, characterFields("experience", session.battle.progress.party));
    try equal(money, session.battle.progress.money);
    session.tick(.{ .confirm = true });
    try equal(.result, session.screen);
    try equal(.victory, session.battle.phase);
    try equal(experience, characterFields("experience", session.battle.progress.party));
}
