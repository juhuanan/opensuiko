const std = @import("std");
const battle = @import("battle");
const party = @import("party_session");
const hq = @import("hq");
const stage_mod = hq.stage;
const windows_mod = hq.windows;
const roster_mod = hq.roster;
const windows_data = @import("hq_data").recruitment_windows;
const roster_data = @import("hq_data").roster;
const campaign = @import("chapters").middle_recruitment;
const data = @import("middle_assets").recruitment;
const identity_data = @import("final_assets").recruitment_map;

const allocator = std.testing.allocator;

fn member(profile: roster_mod.source.Profile, index: usize) battle.OwnedMember {
    return .{
        .id = profile.id,
        .name = profile.name,
        .hp = 40 + @as(u16, @intCast(index % 20)),
        .max_hp = 99,
        .status = .healthy,
        .rune_charges = .{ 1, 2, 3, 4 },
        .max_rune_charges = .{ 4, 4, 4, 4 },
        .inventory = .{},
        .level = 1 + @as(u8, @intCast(index % 40)),
        .experience = @intCast((index * 17) % 1000),
        .base_stats = .{ .attack = 10 + @as(u16, @intCast(index)), .defense = 9, .skill = 8, .speed = 7, .magic = 6, .luck = 5 },
        .weapon_level = 1 + @as(u8, @intCast(index % 16)),
        .loadout = .{ .head = 0 },
        .rune = null,
    };
}

const Fixture = struct {
    contract: std.json.Parsed(campaign.Asset),
    windows: windows_mod.Loaded,
    packet: std.json.Parsed(roster_mod.source.Packet),
    state: campaign.State,
    recruit_flags: [108]u8 = @splat(0),

    fn init(scratch: std.mem.Allocator, stage: stage_mod.Stage, eligible_count: usize) !Fixture {
        const contract = try campaign.open(scratch, data.json);
        const windows = try windows_mod.open(scratch, windows_data.json);
        const packet = try roster_mod.source.load(scratch, roster_data.json);
        if (eligible_count == 0 or eligible_count > packet.value.profiles.len) return error.InvalidFixture;
        var snapshot = party.Snapshot{
            .entry_id = "middle-recruit-entry",
            .content_id = "middle-recruit-content",
            .receipt = "middle-recruit-receipt",
            .baseline_revision = 7,
        };
        for (packet.value.profiles, 0..) |profile, index| {
            snapshot.members[index] = member(profile, index);
            snapshot.extras[index] = .{ .member_id = profile.id };
            snapshot.eligible[index] = index < eligible_count;
        }
        snapshot.active[0] = "hero";
        snapshot.forced[0] = "hero";
        return .{
            .contract = contract,
            .windows = windows,
            .packet = packet,
            .state = try campaign.State.init(packet.value, snapshot, &.{}, stage),
        };
    }

    fn maas(self: *const Fixture) *const windows_mod.Window {
        return windows_mod.windowById(self.windows.asset(), "recruit_window_037").?;
    }

    fn facts(self: *const Fixture) windows_mod.Facts {
        return .{ .interaction = true, .recruit = &self.recruit_flags, .tier = 1 };
    }

    fn recruit(self: *Fixture, story_castle_flag: bool) !?windows_mod.Plan {
        return self.state.recruit(self.packet.value, self.windows.asset(), self.maas(), self.facts(), self.state.revision, 0, story_castle_flag);
    }

    fn maasEligible(self: *const Fixture) bool {
        return self.state.roster.snapshot.eligible[self.state.roster.memberIndex("maas").?];
    }
};

test "asset pins dependencies and the VB6 Maas grant witness" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const fixture = try Fixture.init(arena.allocator(), .one, 1);
    const asset = fixture.contract.value;
    try std.testing.expectEqualStrings("recruit_window_037", asset.maas_witness.window_id);
    try std.testing.expectEqual(@as(u32, 0x35D19), asset.maas_witness.grant_offset);
    try std.testing.expectEqualStrings("45 46", asset.maas_witness.grant_bytes);
    try std.testing.expectEqualStrings(windows_data.asset_sha256, asset.dependencies.windows.sha256);
    try std.testing.expectEqualStrings("ce615fe3fa7cb3bb79c63cb4c6008e856ca1d306eff4e09a6980026bb74baf29", asset.dependencies.roster.sha256);
    try std.testing.expectEqual(@as(u16, 75), asset.coverage.optional_windows);
    try std.testing.expectEqual(@as(u8, 70), fixture.maas().cid);
}

test "admitting Maas once makes the existing record eligible and advances one revision" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .one, 1);
    try std.testing.expect(!fixture.maasEligible());
    const before = fixture.state.revision;
    const plan = (try fixture.recruit(false)).?;
    try std.testing.expectEqual(@as(u8, 70), plan.cid);
    try std.testing.expectEqual(@as(u8, 0x45), plan.op_code);
    try std.testing.expect(fixture.maasEligible());
    try std.testing.expectEqual(before + 1, fixture.state.revision);
    try std.testing.expectEqual(before + 1, fixture.state.roster.revision);
    try std.testing.expectEqual(before + 1, fixture.state.roster.snapshot.baseline_revision);
}

test "duplicate recruitment cannot advance or mutate state" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .one, 1);
    _ = try fixture.recruit(false);
    const revision = fixture.state.revision;
    try std.testing.expectError(error.DuplicateRecruitment, fixture.recruit(false));
    try std.testing.expectEqual(revision, fixture.state.revision);
    try std.testing.expectEqual(revision, fixture.state.roster.snapshot.baseline_revision);
    try std.testing.expect(fixture.maasEligible());
}

test "the verified refusal arm leaves eligibility and revision unchanged" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .one, 1);
    const before = fixture.state.revision;
    const result = try fixture.state.recruit(fixture.packet.value, fixture.windows.asset(), fixture.maas(), fixture.facts(), before, 1, false);
    try std.testing.expect(result == null);
    try std.testing.expect(!fixture.maasEligible());
    try std.testing.expectEqual(before, fixture.state.revision);
    try std.testing.expect(fixture.state.last_window == null);
}

test "a stale expected revision rejects before evaluating or changing state" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .one, 1);
    const before = fixture.state.revision;
    try std.testing.expectError(error.StaleBeforeState, fixture.state.recruit(fixture.packet.value, fixture.windows.asset(), fixture.maas(), fixture.facts(), before + 1, 0, false));
    try std.testing.expect(!fixture.maasEligible());
    try std.testing.expectEqual(before, fixture.state.revision);
}

test "the twenty-fifth Star promotes HQ only with the source story gate" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .one, 26);
    const before = try fixture.state.recount(fixture.packet.value, false);
    try std.testing.expectEqual(@as(u16, 24), before.counts.ever);
    try std.testing.expectEqual(stage_mod.Stage.one, before.stage);
    _ = try fixture.recruit(true);
    try std.testing.expectEqual(stage_mod.Stage.two, fixture.state.stage);
}

test "snapshot restore preserves eligibility and rejects a second grant" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .one, 1);
    _ = try fixture.recruit(false);
    const snapshot = try fixture.state.capture(arena.allocator());
    var restored = try campaign.State.restore(arena.allocator(), fixture.packet.value, snapshot);
    const index = restored.roster.memberIndex("maas").?;
    try std.testing.expect(restored.roster.snapshot.eligible[index]);
    try std.testing.expectEqual(fixture.state.revision, restored.revision);
    try std.testing.expectError(error.DuplicateRecruitment, restored.recruit(fixture.packet.value, fixture.windows.asset(), fixture.maas(), fixture.facts(), restored.revision, 0, false));
    try std.testing.expectEqual(fixture.state.revision, restored.revision);
}

test "a malformed snapshot fails without changing the live state" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .one, 1);
    _ = try fixture.recruit(false);
    var snapshot = try fixture.state.capture(arena.allocator());
    snapshot.roster_json = "not a roster snapshot";
    try std.testing.expectError(error.SyntaxError, campaign.State.restore(arena.allocator(), fixture.packet.value, snapshot));
    try std.testing.expect(fixture.maasEligible());
    try std.testing.expectEqual(@as(u64, 8), fixture.state.revision);
}

const CoverageFixture = struct {
    base: Fixture,
    identities: std.json.Parsed(campaign.RecruitIdentityMap),
    story: [400]u8 = @splat(0),
    party: [108]u8 = @splat(0),
    levels: [108]u8 = @splat(99),
    admission: [108]u8 = @splat(0),
    items: [179]u16,
    equipped: [179]u16,

    fn init(scratch: std.mem.Allocator) !CoverageFixture {
        var result = CoverageFixture{
            .base = try Fixture.init(scratch, .one, 1),
            .identities = try campaign.openIdentityMap(scratch, identity_data.json),
            .items = undefined,
            .equipped = undefined,
        };
        for (&result.items, &result.equipped, 0..) |*item, *equipment, index| {
            item.* = @intCast(index);
            equipment.* = @intCast(index);
        }
        result.party[8] = 1;
        return result;
    }

    fn factsFor(self: *CoverageFixture, window: *const windows_mod.Window) windows_mod.Facts {
        self.base.recruit_flags = self.base.state.recruitFlags(self.base.packet.value);
        self.admission = self.base.recruit_flags;
        var result = windows_mod.Facts{
            .interaction = true,
            .story = &self.story,
            .recruit = &self.admission,
            .party = &self.party,
            .money = std.math.maxInt(i64),
            .items = &self.items,
            .equipped = &self.equipped,
            .levels = &self.levels,
            .tier = 4,
            .eligible = 1,
            .party_count = 1,
            .hero_x = 128,
            .hero_y = 128,
            .input_mask = 0x41,
            .mode_word = std.math.maxInt(u32),
            .random = 0,
        };
        const counts = stage_mod.recount(&self.base.recruit_flags);
        result.eligible = counts.ever;
        for (window.entry.terms) |term| {
            switch (term.kind) {
                .story => {
                    const index = term.byte.?;
                    const mask: u8 = @intCast(term.mask.?);
                    if (std.mem.eql(u8, term.required.?.string, "set")) {
                        self.story[index] |= mask;
                    } else {
                        self.story[index] &= ~mask;
                    }
                },
                .recruit => {
                    const cid = term.cid.?;
                    self.admission[cid] = if (std.mem.eql(u8, term.required.?.string, "absent")) 0 else 1;
                },
                .party => {
                    const cid = term.cid.?;
                    self.party[cid] = if (std.mem.eql(u8, term.required.?.string, "contains")) 1 else 0;
                },
                .party_count => result.party_count = term.count.?,
                .hero_bounds => {
                    const midpoint: u8 = @intCast((@as(u16, term.lower.?) + term.upper.?) / 2);
                    if (term.axis.? == .x) result.hero_x = midpoint else result.hero_y = midpoint;
                },
                .eligible => result.eligible = @max(result.eligible, term.threshold.?),
                else => {},
            }
        }
        return result;
    }
};

test "all 75 source windows preserve 59 unique recruits and 16 duplicate rejections" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture = try CoverageFixture.init(arena.allocator());
    var seen = std.mem.zeroes([108]bool);
    var admitted: u16 = 0;
    var duplicates: u16 = 0;
    for (fixture.base.windows.asset().windows) |*window| {
        const before = fixture.base.state.revision;
        const option: ?u8 = if (window.choice != null) 0 else null;
        const result = fixture.base.state.recruitMapped(fixture.base.packet.value, fixture.base.windows.asset(), window, fixture.factsFor(window), before, option, true, &fixture.identities.value) catch |err| {
            if (err == error.DuplicateRecruitment) {
                try std.testing.expect(seen[window.cid]);
                try std.testing.expectEqual(before, fixture.base.state.revision);
                duplicates += 1;
                continue;
            }
            return err;
        };
        if (result == null) {
            try std.testing.expect(seen[window.cid]);
            try std.testing.expectEqual(before, fixture.base.state.revision);
            duplicates += 1;
            continue;
        }
        try std.testing.expect(!seen[window.cid]);
        seen[window.cid] = true;
        admitted += 1;
        try std.testing.expectEqual(before + 1, fixture.base.state.revision);
    }
    try std.testing.expectEqual(@as(u16, 59), admitted);
    try std.testing.expectEqual(@as(u16, 16), duplicates);
    try std.testing.expectEqual(@as(u64, 66), fixture.base.state.revision);
    try fixture.base.state.roster.validate(fixture.base.packet.value);
    const flags = fixture.base.state.recruitFlags(fixture.base.packet.value);
    try std.testing.expectEqual(@as(u16, 60), stage_mod.recount(&flags).ever);
    var noncombatants: usize = 0;
    for (fixture.base.state.roster.noncombatants) |maybe| {
        if (maybe) |entry| {
            if (entry.recruited) noncombatants += 1;
        }
    }
    try std.testing.expect(noncombatants > 0);
}

test "all 42 verified decline routes leave roster and revision unchanged" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture = try CoverageFixture.init(arena.allocator());
    const snapshot = try fixture.base.state.capture(arena.allocator());
    var declined: u16 = 0;
    for (fixture.base.windows.asset().windows) |*window| {
        const choice = window.choice orelse continue;
        if (!choice.decline_route) continue;
        var state = try campaign.State.restoreMapped(arena.allocator(), fixture.base.packet.value, snapshot, &fixture.identities.value);
        const before = state.revision;
        const result = try state.recruitMapped(fixture.base.packet.value, fixture.base.windows.asset(), window, fixture.factsFor(window), before, 1, false, &fixture.identities.value);
        try std.testing.expect(result == null);
        try std.testing.expectEqual(before, state.revision);
        try std.testing.expect(state.last_window == null);
        const flags = state.recruitFlags(fixture.base.packet.value);
        try std.testing.expectEqual(@as(u16, 1), stage_mod.recount(&flags).ever);
        declined += 1;
    }
    try std.testing.expectEqual(@as(u16, 42), declined);
}
