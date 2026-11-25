//! Focused port check: the 33 spell rules, the proven families, and the
//! C bridge's atomic validate/apply contract.
//!
//! The expected rules come from the generator, but the generator cross-checks
//! them against the D catalogue and asserted instruction words before exporting.
//! The hosts below are hand-authored and independent of the exporter; they are
//! the acceptance cases for charge, retarget, ordering and rollback.

const std = @import("std");
const spells = @import("battle_systems").spells;
const rules = spells.rules;
const plan = spells.plan;
const bridge = spells.bridge;
const asset = @import("battle_systems_data").spell_rules;
const br = @import("battle_rules");

const allocator = std.testing.allocator;

fn loadRules() !std.json.Parsed(rules.Rules) {
    return rules.load(allocator, asset.json);
}

fn sideTarget(comptime side: plan.Side, id: u32, hp: u16, max_hp: u16) plan.Target {
    return .{ .id = id, .side = side, .hp = hp, .max_hp = max_hp };
}

fn add(host: *bridge.Host, target: plan.Target) void {
    host.targets[host.count] = target;
    host.count += 1;
}

fn hostFor(content: []const u8, spell_index: usize) bridge.Host {
    return .{
        .content_id = content,
        .actor = .{ .id = 1, .rune_index = 0, .charges = .{ 2, 1, 1, 1 }, .magic = 10 },
        .rune_spells = .{ spell_index, null, null, null },
        .count = 0,
        .draws = .{ .values = &.{}, .cursor = 0 },
    };
}

fn cast(ruleset: *const rules.Rules, host: *bridge.Host, native_id: u8, target_id: u32) !plan.EffectPlan {
    const index = ruleset.spellIndex(native_id) orelse return error.UnknownSpell;
    host.rune_spells[0] = index;
    const selection = try plan.prepare(ruleset, host.content_id, host.rune_spells, host.actor, .{ .spell_index = index, .target_id = target_id }, host.targets[0..host.count]);
    const committed = try plan.commit(selection);
    return plan.resolve(ruleset, committed, host.content_id, host.rune_spells, host.actor, host.targets[0..host.count], host.draws);
}

fn sameHost(a: bridge.Host, b: bridge.Host) bool {
    if (a.count != b.count or a.actor.id != b.actor.id or a.actor.magic != b.actor.magic) return false;
    if (!std.mem.eql(u16, &a.actor.charges, &b.actor.charges)) return false;
    for (a.targets[0..a.count], b.targets[0..b.count]) |left, right| {
        if (!bridge.sameTarget(left, right)) return false;
    }
    if (a.draws.cursor != b.draws.cursor or a.draws.bios_state != b.draws.bios_state) return false;
    if (!std.mem.eql(u8, a.content_id, b.content_id)) return false;
    return true;
}

fn planEnvelope(content: []const u8, spell_index: usize, expected_charge: u16) plan.EffectPlan {
    return .{
        .content_id = content,
        .actor_id = 1,
        .request = .{ .spell_index = spell_index, .target_id = 1 },
        .expected_charge = expected_charge,
        .tier = 0,
        .charge_after = expected_charge - 1,
        .after = .{ .content_id = content, .actor_id = 1, .request = .{ .spell_index = spell_index, .target_id = 1 }, .tier = 0, .expected_charge = expected_charge, .expected_rune = 0, .stage = .impacted },
        .draws_after = .{},
        .count = 0,
    };
}

// --- accounting -------------------------------------------------------------

test "all 33 definitions are accounted for exactly once" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    try std.testing.expectEqual(@as(usize, 33), ruleset.spells.len);
    const counts = ruleset.counts();
    try std.testing.expectEqual(@as(usize, 33), counts.supported);
    try std.testing.expectEqual(@as(usize, 0), counts.partial);
    try std.testing.expectEqual(@as(usize, 0), counts.blocked);
    var derived: usize = 0;
    for (ruleset.spells, 0..) |spell, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), spell.native_id);
        var id_buffer: [16]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&id_buffer, "spell_{d}", .{index + 1}), spell.id);
        if (std.mem.eql(u8, spell.family_source, "spell_rules.static")) derived += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), derived);
    const guardian = ruleset.spell(33).?;
    try std.testing.expectEqualStrings("supported", guardian.status);
    try std.testing.expect(guardian.blocker == null);
}

test "the spell presentation dependency is typed and stays unavailable" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const dependency = parsed.value.presentation;
    try std.testing.expectEqualStrings("unavailable", dependency.status);
    try std.testing.expectEqualStrings("spell_presentation", dependency.package);
    try std.testing.expectEqualStrings("presentation_correction_unavailable", dependency.code);
    try std.testing.expectEqualStrings("spell_identity_to_presentation_frames_and_audio", dependency.required_interface);
    // No rule row may smuggle a presentation field: the asset has no frame,
    // palette, slot or audio member at all.
    try std.testing.expect(std.mem.indexOf(u8, asset.json, "\"frames\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, asset.json, "\"palette\":") == null);
}

test "the charge thresholds are the source four rows of nine" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const rows = parsed.value.tier_charge.thresholds;
    try std.testing.expectEqualSlices(u8, &.{ 15, 25, 35, 50, 70, 95, 120, 140, 170 }, &rows[0]);
    try std.testing.expectEqualSlices(u8, &.{ 40, 60, 80, 100, 123, 145, 160, 175, 193 }, &rows[1]);
    try std.testing.expectEqualSlices(u8, &.{ 75, 90, 110, 130, 150, 165, 188, 205, 220 }, &rows[2]);
    try std.testing.expectEqualSlices(u8, &.{ 130, 143, 155, 168, 183, 200, 215, 230, 240 }, &rows[3]);
    try std.testing.expectEqualStrings("0x800F5344", parsed.value.tier_charge.spend_routine);
    try std.testing.expectEqualStrings("0x800EF67C", parsed.value.tier_charge.menu_reader);
}

test "the loader refuses an unknown step family or a missing step list" {
    var parsed = try loadRules();
    defer parsed.deinit();
    parsed.value.spells[0].steps[0].op = "teleport";
    try std.testing.expectError(error.UnsupportedStep, parsed.value.validate());

    var clean = try loadRules();
    defer clean.deinit();
    clean.value.spells[0].steps = clean.value.spells[0].steps[0..0];
    try std.testing.expectError(error.InvalidRules, clean.value.validate());
}

// --- admission --------------------------------------------------------------

test "insufficient charge and an unowned spell are refused before any state" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    const index = ruleset.spellIndex(5).?;

    var host = hostFor("content", index);
    add(&host, sideTarget(.enemy, 1, 100, 100));
    const before = host;

    host.actor.charges[0] = 0;
    try std.testing.expectError(error.NoCharge, plan.prepare(ruleset, host.content_id, host.rune_spells, host.actor, .{ .spell_index = index, .target_id = 1 }, host.targets[0..host.count]));
    host = before;

    host.rune_spells = .{ null, null, null, null };
    try std.testing.expectError(error.SpellNotOwned, plan.prepare(ruleset, host.content_id, host.rune_spells, host.actor, .{ .spell_index = index, .target_id = 1 }, host.targets[0..host.count]));
}

test "a charge or target that changes between commit and impact is stale" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    add(&host, sideTarget(.enemy, 1, 100, 100));
    const index = ruleset.spellIndex(5).?;
    host.rune_spells[0] = index;
    const selection = try plan.prepare(ruleset, host.content_id, host.rune_spells, host.actor, .{ .spell_index = index, .target_id = 1 }, host.targets[0..host.count]);
    const committed = try plan.commit(selection);
    host.actor.charges[0] = 7;
    try std.testing.expectError(error.StaleReservation, plan.resolve(ruleset, committed, host.content_id, host.rune_spells, host.actor, host.targets[0..host.count], host.draws));
}

test "retarget keeps a living selection and otherwise picks slot order" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    add(&host, sideTarget(.enemy, 4, 0, 100)); // knocked out
    add(&host, sideTarget(.enemy, 5, 60, 100));
    add(&host, sideTarget(.enemy, 6, 80, 100));
    const index = ruleset.spellIndex(25).?;
    host.rune_spells[0] = index;
    const before = host;

    try std.testing.expectEqual(@as(?u32, 5), try plan.retarget(ruleset, index, 4, host.targets[0..host.count]));
    try std.testing.expectEqual(@as(?u32, 6), try plan.retarget(ruleset, index, 6, host.targets[0..host.count]));
    // The retarget decision itself mutates nothing.
    try std.testing.expect(sameHost(before, host));

    var empty = hostFor("content", index);
    add(&empty, sideTarget(.enemy, 7, 0, 100));
    try std.testing.expectEqual(@as(?u32, null), try plan.retarget(ruleset, index, 7, empty.targets[0..empty.count]));
    try std.testing.expectError(error.TargetUnavailable, plan.prepare(ruleset, empty.content_id, empty.rune_spells, empty.actor, .{ .spell_index = index, .target_id = 7 }, empty.targets[0..empty.count]));
}

// --- proven families --------------------------------------------------------

test "Yell revives, heals a third of maximum HP and cures in source order" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    var fallen = sideTarget(.ally, 2, 0, 90);
    fallen.ko = true;
    fallen.status = 3;
    fallen.sleep = 2;
    add(&host, fallen);
    const effect = try cast(ruleset, &host, 6, 2);
    try std.testing.expectEqual(@as(usize, 1), effect.count);
    const after = effect.changes[0].after;
    try std.testing.expect(!after.ko);
    try std.testing.expectEqual(@as(u16, 30), after.hp);
    try std.testing.expectEqual(@as(u16, 0), after.status);
    try std.testing.expectEqual(@as(u8, 0), after.sleep);
}

test "Mother Ocean revives to full maximum HP and cures" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    var fallen = sideTarget(.ally, 3, 5, 120);
    fallen.ko = true;
    fallen.status = 5;
    add(&host, fallen);
    const effect = try cast(ruleset, &host, 30, 3);
    try std.testing.expect(!effect.changes[0].after.ko);
    try std.testing.expectEqual(@as(u16, 120), effect.changes[0].after.hp);
    try std.testing.expectEqual(@as(u16, 0), effect.changes[0].after.status);
}

test "Shining Wind heals and cures allies before it damages enemies" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    var ally = sideTarget(.ally, 2, 100, 1000);
    ally.status = 4;
    add(&host, ally);
    add(&host, sideTarget(.enemy, 5, 500, 500));
    const effect = try cast(ruleset, &host, 31, 5);
    try std.testing.expectEqual(@as(usize, 2), effect.count);
    try std.testing.expectEqual(plan.Side.ally, effect.changes[0].before.side);
    try std.testing.expectEqual(@as(u16, 600), effect.changes[0].after.hp);
    try std.testing.expectEqual(@as(u16, 0), effect.changes[0].after.status);
    try std.testing.expectEqual(plan.Side.enemy, effect.changes[1].before.side);
    // 500 wind power + 10 magic / 2, neutral affinity.
    try std.testing.expectEqual(@as(u16, 0), effect.changes[1].after.hp);
}

test "the damage consumer agrees with the shared affinity formula" {
    const affinities = [_]br.Affinity{ .neutral, .weak, .resistant, .immune };
    for (0..5) |channel| {
        for (affinities) |affinity| {
            var target = sideTarget(.enemy, 1, 100, 100);
            target.affinity = @splat(if (affinity == .immune) .weak else .immune);
            target.affinity[channel] = affinity;
            for ([_]u16{ 100, 400, 700, 1000 }) |power| {
                const step = rules.Step{ .order = 0, .op = "damage", .target = "selected", .power = power, .channel = @intCast(channel), .resisted = true };
                for ([_]u16{ 0, 1, 65, 255 }) |magic| {
                    const base = @as(u32, power) + magic / 2;
                    const expected = switch (affinity) {
                        .neutral => base,
                        .weak => 2 * base,
                        .resistant => base / 2,
                        .immune => 0,
                    };
                    try std.testing.expectEqual(expected, br.elementalDamage(power, magic, affinity));
                    try std.testing.expectEqual(expected, plan.damageAmount(step, magic, target));
                }
            }
        }
    }
    // Channel 7 is the source's unresisted short-circuit.
    var target = sideTarget(.enemy, 1, 100, 100);
    target.affinity[0] = .immune;
    const unresisted = rules.Step{ .order = 0, .op = "damage", .target = "selected", .power = 300, .channel = 7, .resisted = false };
    try std.testing.expectEqual(@as(u32, 300 + 40 / 2), plan.damageAmount(unresisted, 40, target));
    // Channel 5 is the unnamed sixth column, not an alias of wind or of channel 0.
    var sixth = sideTarget(.enemy, 1, 100, 100);
    sixth.affinity[5] = .weak;
    const channel_five = rules.Step{ .order = 0, .op = "damage", .target = "selected", .power = 70, .channel = 5, .resisted = true };
    try std.testing.expectEqual(@as(u32, (70 + 20 / 2) * 2), plan.damageAmount(channel_five, 20, sixth));
}

test "Scolding is one selected enemy with the sixth affinity column" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    var enemy = sideTarget(.enemy, 1, 100, 100);
    enemy.affinity[5] = .resistant;
    add(&host, enemy);
    const effect = try cast(ruleset, &host, 5, 1);
    // (70 + 10/2) / 2 = 37
    try std.testing.expectEqual(@as(u16, 63), effect.changes[0].after.hp);
}

test "Charm Arrow damages every living enemy and skips the knocked out" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    add(&host, sideTarget(.enemy, 1, 600, 600));
    add(&host, sideTarget(.enemy, 2, 0, 600));
    var dead = host.targets[1];
    dead.ko = true;
    host.targets[1] = dead;
    add(&host, sideTarget(.enemy, 3, 600, 600));
    const effect = try cast(ruleset, &host, 8, 1);
    try std.testing.expectEqual(@as(usize, 2), effect.count);
    try std.testing.expectEqual(@as(u32, 1), effect.changes[0].before.id);
    try std.testing.expectEqual(@as(u32, 3), effect.changes[1].before.id);
}

test "Deadly Fingertips knocks out one enemy unless the source 0x4000 flag blocks it" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    add(&host, sideTarget(.enemy, 1, 400, 400));
    const effect = try cast(ruleset, &host, 25, 1);
    try std.testing.expect(effect.changes[0].after.ko);
    try std.testing.expectEqual(@as(u16, 400), effect.changes[0].after.hp);

    var immune = hostFor("content", 0);
    var boss = sideTarget(.enemy, 1, 400, 400);
    boss.death_immune = true;
    add(&immune, boss);
    const refused = try cast(ruleset, &immune, 25, 1);
    try std.testing.expect(!refused.changes[0].after.ko);
    try std.testing.expectEqual(@as(u16, 400), refused.changes[0].after.hp);
}

test "Hell knocks out every living enemy and respects KO and immunity" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    add(&host, sideTarget(.enemy, 1, 300, 300));
    var boss = sideTarget(.enemy, 2, 300, 300);
    boss.death_immune = true;
    add(&host, boss);
    var dead = sideTarget(.enemy, 3, 0, 300);
    dead.ko = true;
    add(&host, dead);
    const effect = try cast(ruleset, &host, 27, 1);
    try std.testing.expectEqual(@as(usize, 2), effect.count);
    try std.testing.expect(effect.changes[0].after.ko);
    try std.testing.expect(!effect.changes[1].after.ko);
}

test "Guardian of Earth scales defence bonus and leaves HP and status unchanged" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    var first = sideTarget(.ally, 2, 80, 80);
    first.defense_bonus = 10;
    first.skill_bonus = 7;
    add(&host, first);
    var second = sideTarget(.ally, 3, 80, 80);
    second.defense_bonus = -7;
    add(&host, second);
    const effect = try cast(ruleset, &host, 33, 2);
    try std.testing.expectEqual(@as(usize, 2), effect.count);
    try std.testing.expectEqual(@as(i16, 15), effect.changes[0].after.defense_bonus);
    try std.testing.expectEqual(@as(i16, 7), effect.changes[0].after.skill_bonus);
    try std.testing.expectEqual(@as(i16, -10), effect.changes[1].after.defense_bonus);
    // No HP or status effect is invented for the visual reaction.
    try std.testing.expectEqual(@as(u16, 80), effect.changes[0].after.hp);
}

// --- C bridge atomicity ------------------------------------------------------

test "apply commits the target changes and the charge together" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    add(&host, sideTarget(.enemy, 1, 100, 100));
    const effect = try cast(ruleset, &host, 5, 1);
    const draws_before = host.draws;
    try bridge.apply(&host, effect);
    // 70 power + 10 magic / 2 = 75 against a neutral sixth column.
    try std.testing.expectEqual(@as(u16, 25), host.targets[0].hp);
    try std.testing.expectEqual(@as(u16, 1), host.actor.charges[0]);
    try std.testing.expectEqual(draws_before.cursor, host.draws.cursor);
}

test "a late failure keeps the exact before-state and the Draws cursor" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    var host = hostFor("content", 0);
    add(&host, sideTarget(.enemy, 1, 100, 100));
    // Wind of Sleep draws exactly one number from the caller's tape.
    var tape = [_]u15{ 1000, 2000, 3000 };
    host.draws = .{ .values = &tape, .cursor = 1 };
    const effect = try cast(ruleset, &host, 13, 1);
    try std.testing.expectEqual(@as(usize, 2), effect.draws_after.cursor);
    // A later same-update write changes a planned before-state.
    host.targets[0].hp = 99;
    try std.testing.expectError(error.StaleBeforeState, bridge.apply(&host, effect));
    // The failure restored nothing because nothing was written: hp stays 99 and
    // the Draws cursor is still 1.
    try std.testing.expectEqual(@as(u16, 99), host.targets[0].hp);
    try std.testing.expectEqual(@as(usize, 1), host.draws.cursor);
    try std.testing.expectEqual(@as(u16, 2), host.actor.charges[0]);
    // A plan built on the new before-state applies cleanly and consumes the draw.
    var fresh = host;
    const again = try cast(ruleset, &fresh, 13, 1);
    try bridge.apply(&fresh, again);
    try std.testing.expectEqual(@as(usize, 2), fresh.draws.cursor);
    try std.testing.expectEqual(@as(u16, 1), fresh.actor.charges[0]);
}

test "stale charge, unknown target and duplicate changes are refused with no write" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    const index = ruleset.spellIndex(5).?;

    var host = hostFor("content", index);
    add(&host, sideTarget(.enemy, 1, 100, 100));
    add(&host, sideTarget(.enemy, 2, 100, 100));
    const before = host;

    var wrong_charge = planEnvelope("content", index, 5);
    wrong_charge.changes[0] = .{ .before = host.targets[0], .after = host.targets[0] };
    wrong_charge.count = 1;
    try std.testing.expectError(error.StaleCharge, bridge.apply(&host, wrong_charge));
    try std.testing.expect(sameHost(before, host));

    var unknown = planEnvelope("content", index, 2);
    unknown.changes[0] = .{ .before = sideTarget(.enemy, 99, 10, 10), .after = sideTarget(.enemy, 99, 5, 10) };
    unknown.count = 1;
    try std.testing.expectError(error.UnknownTarget, bridge.apply(&host, unknown));
    try std.testing.expect(sameHost(before, host));

    var duplicate = planEnvelope("content", index, 2);
    duplicate.count = 2;
    duplicate.changes[0] = .{ .before = host.targets[0], .after = host.targets[0] };
    duplicate.changes[1] = .{ .before = host.targets[1], .after = host.targets[1] };
    duplicate.changes[1].before.id = 1;
    try std.testing.expectError(error.DuplicateChange, bridge.apply(&host, duplicate));
    try std.testing.expect(sameHost(before, host));

    var wrong_tier = planEnvelope("content", index, 2);
    wrong_tier.count = 1;
    wrong_tier.changes[0] = .{ .before = host.targets[0], .after = host.targets[0] };
    host.rune_spells[0] = index + 1;
    try std.testing.expectError(error.TierSpellMismatch, bridge.apply(&host, wrong_tier));
    host.rune_spells[0] = index;
    try std.testing.expect(sameHost(before, host));
}

test "a plan cannot smuggle a changed identity or capacity" {
    var parsed = try loadRules();
    defer parsed.deinit();
    const ruleset = &parsed.value;
    const index = ruleset.spellIndex(5).?;
    var host = hostFor("content", index);
    add(&host, sideTarget(.enemy, 1, 100, 100));
    var effect = planEnvelope("content", index, 2);
    effect.count = 1;
    var after = host.targets[0];
    after.max_hp = 200;
    effect.changes[0] = .{ .before = host.targets[0], .after = after };
    try std.testing.expectError(error.InvalidPlan, bridge.apply(&host, effect));
    try std.testing.expectEqual(@as(u16, 100), host.targets[0].max_hp);
}

test "Voice of Earth skips airborne damage and wake while grounded and protected targets keep their rules" {
    var parsed = try loadRules();
    defer parsed.deinit();
    var host = hostFor("content", 0);
    var grounded = sideTarget(.enemy, 1, 600, 600);
    grounded.sleep = 1;
    var airborne = sideTarget(.enemy, 2, 600, 600);
    airborne.airborne = true;
    airborne.sleep = 1;
    var protected = sideTarget(.enemy, 3, 600, 600);
    protected.protection = 2;
    add(&host, grounded);
    add(&host, airborne);
    add(&host, protected);
    const effect = try cast(&parsed.value, &host, 22, 1);
    try std.testing.expectEqual(@as(u16, 295), effect.changes[0].after.hp);
    try std.testing.expectEqual(@as(u8, 0), effect.changes[0].after.sleep);
    try std.testing.expectEqualDeep(airborne, effect.changes[1].after);
    try std.testing.expectEqual(@as(u16, 600), effect.changes[2].after.hp);
    airborne.airborne = false;
    try std.testing.expect(!bridge.sameTarget(airborne, effect.changes[1].before));
}
