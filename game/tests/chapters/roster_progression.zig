//! Focused gate: campaign-scale roster progression and ownership.
//!
//! Pure/port-level only: the final roster progression asset and the pinned HQ roster
//! data are embedded, no original instruction, emulator, window, media or
//! user save is touched.  The test admits all 78 combat profiles, exercises
//! active/reserve/follower/absent distinctions, source growth, weapon/rune/
//! equipment changes, knockout/revive/rest and a bounded save/restore round
//! trip, and proves that unknown or aliased references refuse without dropping
//! an owned member.
const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const party = @import("party_session");
const roster_mod = @import("hq").roster;
const roster_data = @import("hq_data").roster;
const roster_chapters = @import("chapters").roster;
const data = @import("final_assets").roster_progression;

const allocator = std.testing.allocator;

const Fixture = struct {
    roster_source: std.json.Parsed(roster_mod.source.Packet),
    packet: roster_chapters.Loaded,
    equipment: [58][]const u8 = undefined,
    runes: [33][]const u8 = undefined,

    fn init() !Fixture {
        const roster_source = try std.json.parseFromSlice(roster_mod.source.Packet, allocator, roster_data.json, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        errdefer roster_source.deinit();
        try roster_source.value.validate();
        var packet = try roster_chapters.open(allocator, data.json);
        errdefer packet.deinit();
        var result = Fixture{ .roster_source = roster_source, .packet = packet };
        for (result.packet.parsed.value.equipment, 0..) |entry, i| result.equipment[i] = entry.id;
        for (result.packet.parsed.value.runes, 0..) |entry, i| result.runes[i] = entry.id;
        return result;
    }
    fn deinit(self: *Fixture) void {
        self.packet.deinit();
        self.roster_source.deinit();
    }
    fn bindings(self: *Fixture) roster_chapters.Bindings {
        return .{ .equipment = &self.equipment, .runes = &self.runes };
    }
    fn ledger(self: *Fixture) !roster_chapters.Ledger {
        return roster_chapters.Ledger.init(self.packet.parsed.value, self.roster_source.value, self.bindings(), "hero");
    }
};

fn admitAll(f: *Fixture, ledger: *roster_chapters.Ledger) !void {
    const asset = f.packet.parsed.value;
    for (asset.profiles) |profile| {
        if (std.mem.eql(u8, profile.id, "hero")) continue;
        _ = try ledger.admit(asset, f.roster_source.value, f.bindings(), profile.id, "test:roster-admit");
    }
}

fn activate(f: *Fixture, ledger: *roster_chapters.Ledger, id: []const u8) !void {
    _ = try ledger.activate(f.packet.parsed.value, f.roster_source.value, f.bindings(), id, "MAIN:0x80139E94");
}

fn replaceValue(allocator_: std.mem.Allocator, bytes: []const u8, value: []const u8) ![]u8 {
    const key = std.mem.indexOf(u8, bytes, "\"profile\"") orelse return error.MissingProfileKey;
    const colon = std.mem.indexOfScalarPos(u8, bytes, key, ':') orelse return error.MissingProfileKey;
    const quote = std.mem.indexOfScalarPos(u8, bytes, colon, '"') orelse return error.MissingProfileKey;
    const end = std.mem.indexOfScalarPos(u8, bytes, quote + 1, '"') orelse return error.MissingProfileKey;
    const out = try allocator_.alloc(u8, bytes.len - (end - quote - 1) + value.len);
    @memcpy(out[0 .. quote + 1], bytes[0 .. quote + 1]);
    @memcpy(out[quote + 1 ..][0..value.len], value);
    @memcpy(out[quote + 1 + value.len ..], bytes[end..]);
    return out;
}

test "asset hash and campaign census are pinned" {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw, .{});
    const actual = std.fmt.bytesToHex(raw, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);

    var f = try Fixture.init();
    defer f.deinit();
    const asset = f.packet.parsed.value;
    try std.testing.expectEqual(@as(usize, 78), asset.profiles.len);
    try std.testing.expectEqual(@as(usize, 108), asset.identities.len);
    try std.testing.expectEqual(@as(usize, 2), asset.guests.len);
    try std.testing.expectEqual(@as(usize, 58), asset.equipment.len);
    try std.testing.expectEqual(@as(usize, 33), asset.runes.len);
    try std.testing.expectEqual(@as(u16, 78), asset.coverage.profiles);
    try std.testing.expectEqual(@as(u16, 108), asset.coverage.identities);
    try std.testing.expectEqual(@as(u16, 76), asset.coverage.bridged_identities);
    try std.testing.expectEqual(@as(u16, 32), asset.coverage.noncombatant_identities);
    try std.testing.expectEqual(@as(u16, 309), asset.coverage.grant_sites);
    try std.testing.expectEqual(@as(u16, 75), asset.coverage.optional_windows);
    try std.testing.expectEqual(@as(u16, 22), asset.coverage.seeded_runes);
    try std.testing.expect(roster_chapters.blocker(asset, "battle_exp_award_open"));
    try std.testing.expect(roster_chapters.blocker(asset, "runtime_bindings_required"));
    try std.testing.expectEqual(@as(u32, 835), asset.rules.stat_table[18]);
    try std.testing.expectEqual(@as(u32, 970), asset.rules.stat_table[21]);
    try std.testing.expectEqual(@as(u32, 2613), asset.rules.hp_table[18]);
    try std.testing.expectEqual(@as(u8, 15), asset.rules.magic_thresholds[0][0]);
}

test "profiles and identities join the pinned HQ and final roster data" {
    var f = try Fixture.init();
    defer f.deinit();
    const asset = f.packet.parsed.value;
    for (asset.profiles) |profile| {
        const previous = f.roster_source.value.profile(profile.id) orelse return error.UnknownProfile;
        try std.testing.expectEqualStrings(previous.name, profile.name);
        try std.testing.expectEqual(previous.source_character_id, profile.source_character_id);
        try std.testing.expectEqual(previous.identity, profile.identity);
        if (profile.identity) |index| {
            const identity = roster_chapters.identity(asset, index).?;
            try std.testing.expectEqualStrings(profile.id, identity.combat_profile_id.?);
        }
    }
    const ted = roster_chapters.profile(asset, "ted").?;
    try std.testing.expect(ted.identity == null);
    try std.testing.expect(roster_chapters.guest(asset, "ted") != null);
    const pahn = roster_chapters.profile(asset, "pahn").?;
    try std.testing.expect(pahn.seed.rune != null);
    try std.testing.expect(pahn.seed.rune.?.locked);
    const flik = roster_chapters.profile(asset, "flik").?;
    try std.testing.expect(flik.seed.rune != null);
    try std.testing.expect(!flik.seed.rune.?.locked);
    const hero = roster_chapters.profile(asset, "hero").?;
    try std.testing.expectEqualStrings("head", roster_chapters.equipment(asset, hero.seed.inventory[0].id).?.class);
}

test "all 78 admitted profiles keep their source seed fields" {
    var f = try Fixture.init();
    defer f.deinit();
    const asset = f.packet.parsed.value;
    var ledger = try f.ledger();
    try admitAll(&f, &ledger);
    try std.testing.expectEqual(@as(usize, 78), ledger.memberCount());
    try std.testing.expectEqual(roster_chapters.Role.active, ledger.role("hero"));
    try std.testing.expectEqual(roster_chapters.Role.reserve, ledger.role("gremio"));
    for (asset.profiles) |profile| {
        const owned = ledger.owned(profile.id).?;
        for (profile.seed.inventory, 0..) |item, slot| if (std.mem.eql(u8, item.id, "sacrificial_buddha")) {
            try std.testing.expectEqual(@as(u16, 1), item.uses);
            try std.testing.expectEqual(field.items.Id.sacrificial_buddha, owned.member.inventory.slots[slot].?.id);
            try std.testing.expectEqual(@as(u16, 0), owned.member.inventory.slots[slot].?.uses);
        };
        try std.testing.expectEqualStrings(profile.name, owned.member.name);
        try std.testing.expectEqual(profile.seed.level, owned.level);
        try std.testing.expectEqual(@as(u32, profile.seed.experience), owned.experience);
        try std.testing.expectEqual(profile.seed.max_hp, owned.member.max_hp);
        try std.testing.expectEqual(profile.seed.weapon.level, owned.weapon_level);
        try std.testing.expectEqual(profile.seed.stats[0] + profile.seed.weapon.powers[profile.seed.weapon.level - 1], owned.stats.attack);
        const sidecar = ledger.extra(profile.id).?;
        try std.testing.expectEqualStrings(profile.id, sidecar.member_id);
        try std.testing.expectEqualDeep(profile.seed.weapon_fragments, sidecar.weapon_fragments);
        const progress = ledger.progressOf(profile.id).?;
        try std.testing.expectEqualStrings(profile.id, progress.profile);
        try std.testing.expectEqual(profile.source_character_id, progress.source_character_id);
        if (profile.seed.rune) |rune_seed| {
            try std.testing.expectEqualStrings(rune_seed.id, progress.rune_id.?);
            try std.testing.expectEqual(rune_seed.locked, progress.rune_locked);
        } else {
            try std.testing.expect(progress.rune_id == null);
        }
    }
}

test "source growth, weapon curve, piece counters and rune/equipment retention" {
    var f = try Fixture.init();
    defer f.deinit();
    const asset = f.packet.parsed.value;
    var ledger = try f.ledger();
    try admitAll(&f, &ledger);
    const rolls = [_]u16{ 0, 0, 0, 0, 0, 0, 0 };
    _ = try ledger.awardExp(asset, f.roster_source.value, f.bindings(), "hero", 1000, &rolls);
    const hero = ledger.owned("hero").?;
    try std.testing.expectEqual(@as(u8, 2), hero.level);
    try std.testing.expectEqual(@as(u32, 0), hero.experience);
    try std.testing.expectEqual(@as(u16, 21), hero.stats.attack);
    try std.testing.expectEqual(@as(u16, 25), hero.stats.skill);
    try std.testing.expectEqual(@as(u16, 20), hero.stats.defense);
    try std.testing.expectEqual(@as(u16, 18), hero.stats.speed);
    try std.testing.expectEqual(@as(u16, 15), hero.stats.magic);
    try std.testing.expectEqual(@as(u16, 18), hero.stats.luck);
    try std.testing.expectEqual(@as(u16, 27), hero.member.max_hp);
    try std.testing.expectEqual(@as(u16, 27), hero.member.hp);
    try std.testing.expectEqual(@as(usize, 1), ledger.activeCount());

    _ = try ledger.awardExp(asset, f.roster_source.value, f.bindings(), "hero", 500, &rolls);
    try std.testing.expectEqual(@as(u32, 500), ledger.owned("hero").?.experience);
    try std.testing.expectError(error.RollsExhausted, ledger.awardExp(asset, f.roster_source.value, f.bindings(), "hero", 500, rolls[0..6]));
    try std.testing.expectEqual(@as(u8, 2), ledger.owned("hero").?.level);
    try std.testing.expectEqual(@as(u32, 500), ledger.owned("hero").?.experience);

    _ = try ledger.raiseWeapon(asset, f.roster_source.value, f.bindings(), "hero");
    try std.testing.expectEqual(@as(u8, 2), ledger.owned("hero").?.weapon_level);
    try std.testing.expectEqual(@as(u16, 23), ledger.owned("hero").?.stats.attack);

    _ = try ledger.applyWeaponPiece(asset, f.roster_source.value, f.bindings(), "hero", .fire, false);
    try std.testing.expectEqualDeep([5]u8{ 1, 0, 0, 0, 0 }, ledger.extra("hero").?.weapon_fragments);
    try std.testing.expectError(error.ReplacementConfirmationRequired, ledger.applyWeaponPiece(asset, f.roster_source.value, f.bindings(), "hero", .water, false));
    _ = try ledger.applyWeaponPiece(asset, f.roster_source.value, f.bindings(), "hero", .water, true);
    try std.testing.expectEqualDeep([5]u8{ 0, 1, 0, 0, 0 }, ledger.extra("hero").?.weapon_fragments);

    _ = try ledger.unequip(asset, f.roster_source.value, f.bindings(), "hero", .head);
    try std.testing.expect(ledger.owned("hero").?.loadout.head == null);
    _ = try ledger.equip(asset, f.roster_source.value, f.bindings(), "hero", .head, "bandanna");
    try std.testing.expect(ledger.owned("hero").?.loadout.head != null);
    try std.testing.expectError(error.SlotMismatch, ledger.equip(asset, f.roster_source.value, f.bindings(), "hero", .body, "bandanna"));
    try std.testing.expectError(error.UnknownResource, ledger.equip(asset, f.roster_source.value, f.bindings(), "hero", .head, "missing"));
    try std.testing.expectError(error.ItemNotOwned, ledger.equip(asset, f.roster_source.value, f.bindings(), "hero", .head, "headband"));

    _ = try activate(&f, &ledger, "flik");
    try std.testing.expectError(error.UnknownResource, ledger.attachRune(asset, f.roster_source.value, f.bindings(), "flik", "missing"));
    _ = try ledger.attachRune(asset, f.roster_source.value, f.bindings(), "flik", "fire_rune");
    try std.testing.expectEqualStrings("fire_rune", ledger.progressOf("flik").?.rune_id.?);
    _ = try ledger.detachRune(asset, f.roster_source.value, f.bindings(), "flik");
    try std.testing.expect(ledger.progressOf("flik").?.rune_id == null);
    _ = try activate(&f, &ledger, "pahn");
    try std.testing.expectError(error.RuneLocked, ledger.detachRune(asset, f.roster_source.value, f.bindings(), "pahn"));
}

test "swap, forced departure and rejoin preserve the owned record and sidecars" {
    var f = try Fixture.init();
    defer f.deinit();
    const asset = f.packet.parsed.value;
    var ledger = try f.ledger();
    try admitAll(&f, &ledger);
    try activate(&f, &ledger, "gremio");
    try activate(&f, &ledger, "cleo");
    const rolls = [_]u16{ 255, 255, 255, 255, 255, 255, 511 };
    _ = try ledger.awardExp(asset, f.roster_source.value, f.bindings(), "gremio", 1000, &rolls);
    _ = try ledger.raiseWeapon(asset, f.roster_source.value, f.bindings(), "gremio");
    _ = try ledger.applyWeaponPiece(asset, f.roster_source.value, f.bindings(), "gremio", .thunder, false);
    const before = ledger.owned("gremio").?;
    const before_extra = ledger.extra("gremio").?;
    const before_progress = ledger.progressOf("gremio").?;

    _ = try ledger.swap(asset, f.roster_source.value, f.bindings(), "gremio", "ted", "MAIN:0x8013A038");
    try std.testing.expectEqual(roster_chapters.Role.reserve, ledger.role("gremio"));
    try std.testing.expectEqual(roster_chapters.Role.active, ledger.role("ted"));
    try std.testing.expectEqualDeep(before, ledger.owned("gremio").?);
    try std.testing.expectEqualDeep(before_extra, ledger.extra("gremio").?);
    try std.testing.expectEqualDeep(before_progress, ledger.progressOf("gremio").?);

    _ = try ledger.swap(asset, f.roster_source.value, f.bindings(), "ted", "gremio", "MAIN:0x80139E94");
    try std.testing.expectEqual(roster_chapters.Role.active, ledger.role("gremio"));
    try std.testing.expectEqualDeep(before, ledger.owned("gremio").?);

    _ = try ledger.forceDepart(asset, f.roster_source.value, f.bindings(), "gremio", .temporary, "MAIN:0x8013A038");
    try std.testing.expectEqual(roster_chapters.Role.reserve, ledger.role("gremio"));
    try std.testing.expectEqualDeep(before, ledger.owned("gremio").?);
    try std.testing.expectEqualDeep(before_extra, ledger.extra("gremio").?);
    _ = try ledger.rejoin(asset, f.roster_source.value, f.bindings(), "gremio", "MAIN:0x80139FBC");
    try std.testing.expectEqual(roster_chapters.Role.active, ledger.role("gremio"));
    try std.testing.expectEqualDeep(before, ledger.owned("gremio").?);

    const cleo_before = ledger.owned("cleo").?;
    _ = try ledger.forceDepart(asset, f.roster_source.value, f.bindings(), "cleo", .permanent, "MAIN:0x8013A0C0");
    try std.testing.expectEqual(roster_chapters.Role.absent, ledger.role("cleo"));
    try std.testing.expectEqualDeep(cleo_before, ledger.owned("cleo").?);
    try std.testing.expect(ledger.owned("cleo") != null);
}

test "active, reserve and follower distinctions hold at 78 members" {
    var f = try Fixture.init();
    defer f.deinit();
    const asset = f.packet.parsed.value;
    var ledger = try f.ledger();
    try admitAll(&f, &ledger);
    for ([_][]const u8{ "gremio", "cleo", "pahn", "flik", "luc" }) |id| try activate(&f, &ledger, id);
    try std.testing.expectEqual(@as(usize, 6), ledger.activeCount());
    const followers = [6]?[]const u8{ "flik", "ted", null, null, null, null };
    _ = try ledger.setFollowers(asset, f.roster_source.value, f.bindings(), followers);
    try std.testing.expectEqual(roster_chapters.Role.active, ledger.role("flik"));
    try std.testing.expectEqual(roster_chapters.Role.follower, ledger.role("ted"));
    var reserve: usize = 0;
    for (asset.profiles) |profile| if (ledger.role(profile.id) == .reserve) {
        reserve += 1;
    };
    try std.testing.expectEqual(@as(usize, 71), reserve);
    _ = try ledger.forceDepart(asset, f.roster_source.value, f.bindings(), "flik", .temporary, "MAIN:0x8013A038");
    try std.testing.expectEqual(roster_chapters.Role.reserve, ledger.role("flik"));
    try std.testing.expectEqual(roster_chapters.Role.follower, ledger.role("ted"));
    try std.testing.expectEqual(@as(usize, 5), ledger.activeCount());
    _ = try ledger.setFollowers(asset, f.roster_source.value, f.bindings(), .{ null, null, null, null, null, null });
    try std.testing.expectEqual(roster_chapters.Role.reserve, ledger.role("ted"));
}

test "knockout, revive, rest and reload preserve progression fields" {
    var f = try Fixture.init();
    defer f.deinit();
    const asset = f.packet.parsed.value;
    var ledger = try f.ledger();
    try admitAll(&f, &ledger);
    try activate(&f, &ledger, "gremio");
    const rolls = [_]u16{ 0, 0, 0, 0, 0, 0, 0 };
    _ = try ledger.awardExp(asset, f.roster_source.value, f.bindings(), "gremio", 1000, &rolls);
    _ = try ledger.raiseWeapon(asset, f.roster_source.value, f.bindings(), "gremio");
    _ = try ledger.applyWeaponPiece(asset, f.roster_source.value, f.bindings(), "gremio", .earth, false);
    const before = ledger.owned("gremio").?;
    const before_extra = ledger.extra("gremio").?;
    _ = try ledger.knockout(asset, f.roster_source.value, f.bindings(), "gremio", "MAIN:0x800E9CC4");
    try std.testing.expectEqual(field.game_state.Status.unconscious, ledger.owned("gremio").?.member.status);
    try std.testing.expectEqual(@as(u16, 0), ledger.owned("gremio").?.member.hp);
    try std.testing.expectEqualDeep(before_extra, ledger.extra("gremio").?);
    _ = try ledger.revive(asset, f.roster_source.value, f.bindings(), "gremio", "MAIN:0x800E9CC4");
    try std.testing.expectEqual(field.game_state.Status.healthy, ledger.owned("gremio").?.member.status);
    try std.testing.expectEqual(before.member.hp, ledger.owned("gremio").?.member.hp);
    _ = try ledger.rest(asset, f.roster_source.value, f.bindings(), "gremio");
    try std.testing.expectEqual(ledger.owned("gremio").?.member.max_hp, ledger.owned("gremio").?.member.hp);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try ledger.capture(arena.allocator());
    var restored = try roster_chapters.Ledger.restore(arena.allocator(), asset, f.roster_source.value, f.bindings(), bytes);
    try std.testing.expectEqualDeep(ledger.base.snapshot, restored.base.snapshot);
    try std.testing.expectEqualDeep(ledger.base.states, restored.base.states);
    try std.testing.expectEqualDeep(ledger.progress, restored.progress);
    const again = try restored.capture(arena.allocator());
    try std.testing.expectEqualStrings(bytes, again);
    try std.testing.expectEqual(roster_chapters.Role.active, restored.role("gremio"));
    try std.testing.expectEqual(roster_chapters.Role.reserve, restored.role("cleo"));
}

test "unknown and aliased references refuse atomically" {
    var f = try Fixture.init();
    defer f.deinit();
    const asset = f.packet.parsed.value;
    var ledger = try f.ledger();
    const hero_before = ledger.owned("hero").?;
    try std.testing.expectError(error.UnknownProfile, ledger.admit(asset, f.roster_source.value, f.bindings(), "missing", "test:missing"));
    try std.testing.expectEqual(@as(usize, 1), ledger.memberCount());
    try std.testing.expectEqualDeep(hero_before, ledger.owned("hero").?);
    try std.testing.expectError(error.UnknownResource, ledger.equip(asset, f.roster_source.value, f.bindings(), "hero", .head, "missing"));
    try std.testing.expectError(error.UnknownResource, ledger.attachRune(asset, f.roster_source.value, f.bindings(), "hero", "missing"));
    try std.testing.expectEqualDeep(hero_before, ledger.owned("hero").?);

    var empty_runes: [0][]const u8 = .{};
    const bad_runes = roster_chapters.Bindings{ .equipment = &f.equipment, .runes = &empty_runes };
    try std.testing.expectError(error.UnknownResource, ledger.admit(asset, f.roster_source.value, bad_runes, "pahn", "test:missing-rune"));
    try std.testing.expectEqual(@as(usize, 1), ledger.memberCount());
    try std.testing.expectEqualDeep(hero_before, ledger.owned("hero").?);

    var empty_equipment: [0][]const u8 = .{};
    const bad_equipment = roster_chapters.Bindings{ .equipment = &empty_equipment, .runes = &f.runes };
    try std.testing.expectError(error.UnknownResource, ledger.admit(asset, f.roster_source.value, bad_equipment, "gremio", "test:missing-equipment"));
    try std.testing.expectEqual(@as(usize, 1), ledger.memberCount());
    try std.testing.expectEqualDeep(hero_before, ledger.owned("hero").?);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try ledger.capture(arena.allocator());
    const tampered = try replaceValue(arena.allocator(), bytes, "gremio");
    try std.testing.expectError(error.AliasedMember, roster_chapters.Ledger.restore(arena.allocator(), asset, f.roster_source.value, f.bindings(), tampered));
    const oversized = try arena.allocator().alloc(u8, roster_chapters.max_state_bytes + 1);
    @memset(oversized, 0);
    try std.testing.expectError(error.SaveTooLarge, roster_chapters.Ledger.restore(arena.allocator(), asset, f.roster_source.value, f.bindings(), oversized));
    try std.testing.expectEqualDeep(hero_before, ledger.owned("hero").?);
}

test "weapon maximum and locked equipment refuse without mutation" {
    var f = try Fixture.init();
    defer f.deinit();
    const asset = f.packet.parsed.value;
    var ledger = try f.ledger();
    try admitAll(&f, &ledger);
    try activate(&f, &ledger, "odessa");
    const odessa_before = ledger.owned("odessa").?;
    try std.testing.expectError(error.EquipmentLocked, ledger.unequip(asset, f.roster_source.value, f.bindings(), "odessa", .head));
    try std.testing.expectEqualDeep(odessa_before, ledger.owned("odessa").?);
    var level: u8 = ledger.owned("hero").?.weapon_level;
    while (level < 16) : (level += 1) {
        _ = try ledger.raiseWeapon(asset, f.roster_source.value, f.bindings(), "hero");
    }
    try std.testing.expectEqual(@as(u8, 16), ledger.owned("hero").?.weapon_level);
    const maxed = ledger.owned("hero").?;
    try std.testing.expectError(error.WeaponMaxed, ledger.raiseWeapon(asset, f.roster_source.value, f.bindings(), "hero"));
    try std.testing.expectEqualDeep(maxed, ledger.owned("hero").?);
}
