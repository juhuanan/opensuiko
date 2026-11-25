//! Battle outcomes focused checks: scripted and boss battle outcomes.
//!
//! The cases verify the module acceptance facts, not a walkthrough:
//!   * the outcomes asset validates, keeps its disclosures and its blocked rows;
//!   * the three event-0x47 forms and the real callers are present;
//!   * victory, no-reward end, defeat and the open battle classify as the source
//!     says, and rewards need both result flags clear;
//!   * a defeat routes to the GAMEOVER selector, never to a story mutation;
//!   * an open battle and a 0x4000 boss cannot become a generic victory;
//!   * the host commits exactly once, and a snapshot taken mid-result restores
//!     the same owner and the same pending consequence;
//!   * a foreign owner cannot adopt the transition.
//!
//! No original instruction is executed.  The outcomes asset is generated from
//! static source facts.

const std = @import("std");
const outcomes_mod = @import("battle_systems").outcomes;
const data = @import("battle_systems_data").outcomes;

fn openPacket() !outcomes_mod.Opened {
    return outcomes_mod.open(std.testing.allocator, data.json);
}

fn battleOf(asset: *const outcomes_mod.Asset, id: []const u8) *const outcomes_mod.Battle {
    return outcomes_mod.battleById(asset, id) orelse unreachable;
}

fn firstBossBattle(asset: *const outcomes_mod.Asset) *const outcomes_mod.Battle {
    for (asset.battles) |*battle| if (battle.boss_present) return battle;
    unreachable;
}

fn firstPlainBattle(asset: *const outcomes_mod.Asset) *const outcomes_mod.Battle {
    for (asset.battles) |*battle| if (!battle.boss_present) return battle;
    unreachable;
}

test "packet validates and keeps its qualifiers" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    try std.testing.expectEqualStrings(outcomes_mod.schema, asset.schema);
    try std.testing.expectEqual(@as(usize, 71), asset.battles.len);
    try std.testing.expectEqual(@as(usize, 8), asset.bosses.len);
    try std.testing.expectEqual(@as(usize, 2), asset.callers.len);
    try std.testing.expect(asset.disclosures.len >= 5);

    // Every battle came from a real room and a hashed overlay, and every enemy
    // slot resolves to a declared record.
    for (asset.battles) |battle| {
        try std.testing.expect(battle.rooms.len > 0);
        try std.testing.expect(battle.room_reachable);
        try std.testing.expectEqual(@as(usize, 64), battle.source_sha256.len);
        for (battle.encounters) |encounter| {
            try std.testing.expectEqual(@as(usize, encounter.active), encounter.enemy_ids.len);
            for (encounter.enemy_ids) |id| try std.testing.expect(outcomes_mod.enemyById(asset, id) != null);
        }
    }
}

test "entry contract keeps the three opcode-0x47 forms" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    try std.testing.expectEqualStrings("0x47", asset.entry_contract.opcode);
    try std.testing.expectEqualStrings("0x801394D0", asset.entry_contract.handler);
    var special = false;
    var mode5 = false;
    var encounter = false;
    for (asset.entry_contract.forms) |form| {
        if (std.mem.eql(u8, form.selector, "0xFF")) {
            special = form.mode == 4 and form.operand_bytes == 2;
        } else if (std.mem.eql(u8, form.selector, "0xFE")) {
            mode5 = form.mode == 5 and form.operand_bytes == 1;
        } else if (std.mem.eql(u8, form.selector, "other")) {
            encounter = form.mode == 3 and form.operand_bytes == 1;
        }
    }
    try std.testing.expect(special and mode5 and encounter);

    // The room chain is the source chain, not a guess.
    try std.testing.expectEqualStrings("u32(root+4)", asset.entry_contract.room_chain.section_table);
    try std.testing.expectEqualStrings("0x1C", asset.entry_contract.room_chain.header_base_field);
    try std.testing.expectEqualStrings("0x20", asset.entry_contract.room_chain.header_table_field);
    try std.testing.expectEqualStrings("0x80000000", asset.entry_contract.encounter.escape_bit);
    try std.testing.expectEqualStrings("0x40000000", asset.entry_contract.encounter.archive_bit);
}

test "real callers decode as opcode 0x47" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    var special = false;
    var normal = false;
    for (asset.callers) |caller| {
        try std.testing.expectEqualStrings("0x47", caller.opcode);
        try std.testing.expect(std.mem.startsWith(u8, caller.bytes, "47"));
        try std.testing.expectEqualStrings("unproven", caller.room_link);
        if (std.mem.eql(u8, caller.selector, "0xFF")) {
            special = std.mem.eql(u8, caller.bytes, "47ff0b03") and caller.mode == 4;
        }
        if (std.mem.eql(u8, caller.selector, "0x00")) {
            normal = std.mem.eql(u8, caller.bytes, "4700fd") and caller.mode == 3;
        }
    }
    try std.testing.expect(special and normal);
}

test "flag families match the escape and archive bits" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    var boss_archive: usize = 0;
    var standard_archive: usize = 0;
    var no_escape: usize = 0;
    var boss_standard: usize = 0;
    for (asset.battles) |battle| {
        const archive_boss = battle.flags & 0x40000000 != 0;
        if (archive_boss) boss_archive += 1 else standard_archive += 1;
        if (!battle.escape_allowed) no_escape += 1;
        try std.testing.expectEqual(archive_boss, std.mem.eql(u8, battle.archive, "boss"));
        if (battle.boss_present and !archive_boss) boss_standard += 1;
        if (battle.boss_present) {
            try std.testing.expectEqualStrings("unproven", battle.end_trigger);
        } else {
            try std.testing.expectEqualStrings("live_count", battle.end_trigger);
        }
    }
    // Real records exercise both archives, the no-escape branch and a boss in
    // the standard archive; none of these are synthetic.
    try std.testing.expect(boss_archive > 0);
    try std.testing.expect(standard_archive > 0);
    try std.testing.expect(no_escape > 0);
    try std.testing.expect(boss_standard > 0);
}

test "classify: the source's four result states" {
    const victory = outcomes_mod.classify(.{ .live_enemies = 0, .end_flag = false, .defeat_flag = false });
    try std.testing.expectEqual(outcomes_mod.Branch.victory, victory.branch);
    try std.testing.expect(victory.rewards);
    try std.testing.expect(victory.action == .return_to_field);

    const end = outcomes_mod.classify(.{ .live_enemies = 3, .end_flag = true, .defeat_flag = false });
    try std.testing.expectEqual(outcomes_mod.Branch.no_reward_end, end.branch);
    try std.testing.expect(!end.rewards);
    try std.testing.expect(end.action == .return_to_field);

    const defeat = outcomes_mod.classify(.{ .live_enemies = 3, .end_flag = false, .defeat_flag = true });
    try std.testing.expectEqual(outcomes_mod.Branch.defeat, defeat.branch);
    try std.testing.expect(!defeat.rewards);
    try std.testing.expectEqual(@as(u8, 0x0A), defeat.action.special_module);

    const open = outcomes_mod.classify(.{ .live_enemies = 1, .end_flag = false, .defeat_flag = false });
    try std.testing.expectEqual(outcomes_mod.Branch.battle_open, open.branch);
    try std.testing.expect(!open.rewards);
    try std.testing.expect(open.action == .none);

    // A defeat with a stale end flag still routes to the game-over module,
    // because the teardown reads the defeat flag for routing.
    const both = outcomes_mod.classify(.{ .live_enemies = 0, .end_flag = true, .defeat_flag = true });
    try std.testing.expectEqual(outcomes_mod.Branch.defeat, both.branch);
    try std.testing.expectEqual(@as(u8, 0x0A), both.action.special_module);
}

test "reward eligibility is the two-flag gate" {
    // Only the all-clear state rewards; every exceptional state skips the result
    // initializer at 0x800DE178..0x800DE184.
    var cases: [8]outcomes_mod.Signal = undefined;
    var live: u32 = 0;
    var index: usize = 0;
    while (live <= 1) : (live += 1) {
        var mask: u8 = 0;
        while (mask < 4) : (mask += 1) {
            cases[index] = .{
                .live_enemies = live,
                .end_flag = (mask & 1) != 0,
                .defeat_flag = (mask & 2) != 0,
            };
            index += 1;
        }
    }
    for (cases) |signal| {
        const result = outcomes_mod.classify(signal);
        const expected = signal.live_enemies == 0 and !signal.end_flag and !signal.defeat_flag;
        try std.testing.expectEqual(expected, result.rewards);
    }
}

test "battle classification refuses a boss victory without an end request" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const boss_battle = firstBossBattle(asset);

    // 0x4000 skips the live-count decrement, so a zero count with both flags
    // clear cannot be the truth of this battle.
    try std.testing.expectError(error.InconsistentLiveCount, outcomes_mod.classifyBattle(boss_battle, .{
        .live_enemies = 0,
        .end_flag = false,
        .defeat_flag = false,
    }));

    // The source's scripted end is the only clean exit: no rewards, field return.
    const ended = try outcomes_mod.classifyBattle(boss_battle, .{
        .live_enemies = 1,
        .end_flag = true,
        .defeat_flag = false,
    });
    try std.testing.expectEqual(outcomes_mod.Branch.no_reward_end, ended.branch);
    try std.testing.expect(!ended.rewards);

    // Defeat is still defeat.
    const lost = try outcomes_mod.classifyBattle(boss_battle, .{
        .live_enemies = 1,
        .end_flag = false,
        .defeat_flag = true,
    });
    try std.testing.expectEqual(outcomes_mod.Branch.defeat, lost.branch);

    // While the boss is fielded with no end request the answer is pending.
    const pending = try outcomes_mod.classifyBattle(boss_battle, .{
        .live_enemies = 1,
        .end_flag = false,
        .defeat_flag = false,
    });
    try std.testing.expectEqual(outcomes_mod.Branch.battle_open, pending.branch);
    try std.testing.expect(pending.action == .none);
}

test "host commits a resolved consequence exactly once" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const battle = firstPlainBattle(asset);

    var host = outcomes_mod.Host{};
    try host.begin(battle, 0xA11CE);
    const result = try host.resolve(battle, .{
        .live_enemies = 0,
        .end_flag = false,
        .defeat_flag = false,
    });
    try std.testing.expectEqual(outcomes_mod.Branch.victory, result.branch);

    const receipt = try host.commit();
    try std.testing.expectEqualStrings(battle.id, receipt.id());
    try std.testing.expect(receipt.rewards);
    try std.testing.expectEqual(@as(u32, 1), receipt.sequence);
    try std.testing.expectError(error.AlreadyCommitted, host.commit());
    try std.testing.expectError(error.AlreadyCommitted, host.commit());
    try std.testing.expectEqual(outcomes_mod.Phase.committed, host.phase);
}

test "open battle stays pending and cannot commit" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const battle = firstPlainBattle(asset);

    var host = outcomes_mod.Host{};
    try host.begin(battle, 7);
    const result = try host.resolve(battle, .{
        .live_enemies = 2,
        .end_flag = false,
        .defeat_flag = false,
    });
    try std.testing.expectEqual(outcomes_mod.Branch.battle_open, result.branch);
    try std.testing.expectEqual(outcomes_mod.Phase.pending, host.phase);
    try std.testing.expectError(error.ResultPending, host.commit());

    // The battle can resolve later without losing ownership.
    const ended = try host.resolve(battle, .{
        .live_enemies = 0,
        .end_flag = false,
        .defeat_flag = false,
    });
    try std.testing.expectEqual(outcomes_mod.Branch.victory, ended.branch);
    _ = try host.commit();
}

test "mid-result restart preserves ownership and the pending consequence" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const battle = firstPlainBattle(asset);

    var first = outcomes_mod.Host{};
    try first.begin(battle, 0xC0FFEE);
    const result = try first.resolve(battle, .{
        .live_enemies = 0,
        .end_flag = true,
        .defeat_flag = false,
    });
    try std.testing.expectEqual(outcomes_mod.Branch.no_reward_end, result.branch);

    // Restart between resolve and commit: the snapshot is all the host has.
    const snapshot = first.capture();
    var second = outcomes_mod.Host{};
    try second.adopt(snapshot, 0xC0FFEE);
    try std.testing.expectEqual(first.token, second.token);
    try std.testing.expectEqualStrings(battle.id, second.id());
    try std.testing.expectEqual(outcomes_mod.Phase.resolved, second.phase);

    const receipt = try second.commit();
    try std.testing.expectEqual(outcomes_mod.Branch.no_reward_end, receipt.branch);
    try std.testing.expect(!receipt.rewards);
    try std.testing.expectError(error.AlreadyCommitted, second.commit());

    // The original host had not committed; a second snapshot cannot double it.
    try std.testing.expectError(error.HostBusy, second.restore(snapshot));
}

test "a foreign owner cannot adopt or restore the transition" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const battle = firstPlainBattle(asset);

    var first = outcomes_mod.Host{};
    try first.begin(battle, 11);
    _ = try first.resolve(battle, .{
        .live_enemies = 0,
        .end_flag = false,
        .defeat_flag = false,
    });
    const snapshot = first.capture();

    var foreign = outcomes_mod.Host{};
    try std.testing.expectError(error.OwnershipMismatch, foreign.adopt(snapshot, 12));
    try std.testing.expectEqual(outcomes_mod.Phase.idle, foreign.phase);

    // A snapshot without an owner is not a transition.
    var ownerless = snapshot;
    ownerless.token = 0;
    try std.testing.expectError(error.OwnershipMissing, foreign.restore(ownerless));
}

test "pending and blocked states never become a generic victory" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    // The packet publishes the four blocked families explicitly.
    var story = false;
    var defeat = false;
    var branch = false;
    var boss = false;
    var gameover = false;
    for (asset.blocked) |row| {
        if (std.mem.eql(u8, row.id, "story_continues_after_defeat")) story = true;
        if (std.mem.eql(u8, row.id, "permitted_defeat")) defeat = true;
        if (std.mem.eql(u8, row.id, "script_branch_on_result")) branch = true;
        if (std.mem.eql(u8, row.id, "boss_end_trigger")) boss = true;
        if (std.mem.eql(u8, row.id, "gameover_screens")) gameover = true;
        try std.testing.expect(row.reason.len > 0);
    }
    try std.testing.expect(story and defeat and branch and boss and gameover);
    try std.testing.expectEqualStrings("blocked", asset.continuation.story_continuation_after_defeat);
    try std.testing.expectEqualStrings("unproven", asset.continuation.script_observes_result);
    try std.testing.expectEqualStrings("blocked", asset.continuation.permitted_defeat);

    // A defeat is a host action, not a story edit.
    const result = outcomes_mod.classify(.{ .live_enemies = 1, .end_flag = false, .defeat_flag = true });
    try std.testing.expectEqual(outcomes_mod.Branch.defeat, result.branch);
    try std.testing.expectEqual(@as(u8, 0x0A), result.action.special_module);
    try std.testing.expect(std.mem.endsWith(u8, asset.result_contract.teardown.defeat_route.module, "GAMEOVER.BIN"));
}

test "a host needs an explicit owner token" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const battle = firstPlainBattle(asset);
    var host = outcomes_mod.Host{};
    try std.testing.expectError(error.OwnershipMissing, host.begin(battle, 0));
    try std.testing.expectEqual(outcomes_mod.Phase.idle, host.phase);
}

test "a boss battle with both flags set is still a defeat" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const boss_battle = firstBossBattle(asset);
    const result = try outcomes_mod.classifyBattle(boss_battle, .{
        .live_enemies = 0,
        .end_flag = true,
        .defeat_flag = true,
    });
    try std.testing.expectEqual(outcomes_mod.Branch.defeat, result.branch);
    try std.testing.expectEqual(@as(u8, 0x0A), result.action.special_module);
    try std.testing.expect(!result.rewards);
}

test "packet refuses an unknown continuation state" {
    const json = try std.testing.allocator.dupe(u8, data.json);
    defer std.testing.allocator.free(json);
    const old = "story_continuation_after_defeat";
    const at = std.mem.indexOf(u8, json, old) orelse unreachable;
    const blocked_at = std.mem.indexOfPos(u8, json, at, "\"blocked\"") orelse unreachable;
    const replacement = "refused";
    try std.testing.expectEqual(replacement.len, "blocked".len);
    @memcpy(json[blocked_at + 1 ..][0..replacement.len], replacement);
    try std.testing.expectError(error.ContinuationStateInvalid, outcomes_mod.open(std.testing.allocator, json));
}

test "packet refuses a doctored schema" {
    const json = try std.testing.allocator.dupe(u8, data.json);
    defer std.testing.allocator.free(json);
    const needle = outcomes_mod.schema;
    const at = std.mem.indexOf(u8, json, needle) orelse unreachable;
    json[at + needle.len - 1] = '9';
    try std.testing.expectError(error.UnsupportedSchema, outcomes_mod.open(std.testing.allocator, json));
}

test "every battle id is unique and addressable" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    for (asset.battles, 0..) |battle, i| {
        try std.testing.expect(outcomes_mod.battleById(asset, battle.id) != null);
        for (asset.battles[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, battle.id, other.id));
        }
    }
}
