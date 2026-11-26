const std = @import("std");
const hq = @import("hq");
const hq_windows = hq.windows;
const hq_roster = hq.roster;
const hq_stage = hq.stage;
const party = @import("party_session");

pub const schema = "suikoden-middle-recruitment/1";

pub const Dependency = struct { sha256: []const u8 };
pub const Dependencies = struct {
    windows: Dependency,
    roster: Dependency,
    windows_module: Dependency,
    roster_module: Dependency,
    stage_module: Dependency,
    identity_map: Dependency,
};
pub const MaasWitness = struct {
    window_id: []const u8,
    recruit_id: u8,
    grant_offset: u32,
    grant_bytes: []const u8,
    tier_minimum: u8,
    accept_route: []const u8,
    duplicate_route: []const u8,
    decline_route: []const u8,
};
pub const CallbackWitness = struct {
    source_file: []const u8,
    callback_address: u32,
    grant_offset: u32,
    return_address: u32,
    cursor_writes: u8,
};
pub const Coverage = struct {
    optional_windows: u16,
    optional_identities: u16,
    adapter_witnesses: u16,
    duplicate_windows_rejected: u16,
    decline_witnesses: u16,
    source_graph_blockers: u16,
    callback_proof_witnesses: u16,
    canonical_route_witnesses: u16,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    dependencies: Dependencies,
    maas_witness: MaasWitness,
    callback_witnesses: []const CallbackWitness,
    coverage: Coverage,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64)
        return error.InvalidRecruitmentSchema;
    const witness = asset.maas_witness;
    if (witness.recruit_id != 70 or witness.grant_offset != 0x35D19 or
        !std.mem.eql(u8, witness.grant_bytes, "45 46") or witness.tier_minimum != 1 or
        !std.mem.eql(u8, witness.accept_route, "admit_once_set_recruit_and_recount") or
        !std.mem.eql(u8, witness.duplicate_route, "already_recruited_no_mutation") or
        !std.mem.eql(u8, witness.decline_route, "declined_no_mutation"))
        return error.InvalidRecruitmentWitness;
    if (asset.coverage.optional_windows != 75 or asset.coverage.optional_identities != 59 or
        asset.coverage.adapter_witnesses != 59 or asset.coverage.duplicate_windows_rejected != 16 or
        asset.coverage.decline_witnesses != 42 or asset.coverage.source_graph_blockers != 0 or
        asset.coverage.callback_proof_witnesses != 2 or asset.coverage.canonical_route_witnesses != 0)
        return error.InvalidRecruitmentCoverage;
    if (asset.callback_witnesses.len != 2) return error.InvalidCallbackWitness;
    const expected = [_]CallbackWitness{
        .{ .source_file = "DATA/02_AREA.B/VB5BG.BIN", .callback_address = 0x80011080, .grant_offset = 298547, .return_address = 0x80011204, .cursor_writes = 0 },
        .{ .source_file = "DATA/02_AREA.B/VB5CG.BIN", .callback_address = 0x80010BC4, .grant_offset = 300488, .return_address = 0x80010D48, .cursor_writes = 0 },
    };
    for (asset.callback_witnesses, expected) |actual, wanted| {
        if (!std.mem.eql(u8, actual.source_file, wanted.source_file) or actual.callback_address != wanted.callback_address or
            actual.grant_offset != wanted.grant_offset or actual.return_address != wanted.return_address or
            actual.cursor_writes != 0) return error.InvalidCallbackWitness;
    }
}

pub const RecruitIdentity = struct { recruit_id: u8, portrait_index: u16 };
pub const RecruitIdentityMap = struct { identities: []const RecruitIdentity };

pub fn openIdentityMap(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(RecruitIdentityMap) {
    const parsed = try std.json.parseFromSlice(RecruitIdentityMap, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    if (parsed.value.identities.len != 108) return error.InvalidRecruitmentIdentityMap;
    var seen_recruit = std.mem.zeroes([108]bool);
    var seen_portrait = std.mem.zeroes([108]bool);
    for (parsed.value.identities) |entry| {
        if (entry.recruit_id >= 108 or entry.portrait_index >= 108 or
            seen_recruit[entry.recruit_id] or seen_portrait[entry.portrait_index])
            return error.InvalidRecruitmentIdentityMap;
        seen_recruit[entry.recruit_id] = true;
        seen_portrait[entry.portrait_index] = true;
    }
    return parsed;
}

pub const Snapshot = struct {
    stage: hq_stage.Stage,
    revision: u64,
    last_window: ?[]const u8,
    roster_json: []const u8,
};

pub const State = struct {
    roster: hq_roster.roster.Roster,
    stage: hq_stage.Stage,
    revision: u64,
    last_window: ?[]const u8 = null,
    identities: ?*const RecruitIdentityMap = null,

    pub fn init(packet: hq_roster.source.Packet, snapshot: party.Snapshot, noncombatants: []const hq_roster.roster.NoncombatantState, stage: hq_stage.Stage) !State {
        const roster = try hq_roster.roster.Roster.init(packet, snapshot, noncombatants);
        return .{ .roster = roster, .stage = stage, .revision = roster.revision };
    }

    pub fn recruitFlags(self: *const State, packet: hq_roster.source.Packet) [108]u8 {
        var result = std.mem.zeroes([108]u8);
        for (self.roster.snapshot.members, 0..) |maybe, index| {
            if (maybe == null or !self.roster.snapshot.eligible[index]) continue;
            const member = maybe.?;
            for (packet.profiles) |profile| {
                if (std.mem.eql(u8, profile.id, member.id)) {
                    if (profile.source_character_id < result.len) result[profile.source_character_id] |= 1;
                    break;
                }
            }
        }
        for (self.roster.noncombatants) |maybe| {
            if (maybe) |entry| {
                if (!entry.recruited) continue;
                if (self.identities) |map| {
                    for (map.identities) |identity| {
                        if (identity.portrait_index == entry.identity) {
                            result[identity.recruit_id] |= 1;
                            break;
                        }
                    }
                } else {
                    result[entry.identity] |= 1;
                }
            }
        }
        return result;
    }

    pub fn recount(self: *State, packet: hq_roster.source.Packet, story_castle_flag: bool) !hq_stage.Plan {
        const flags = self.recruitFlags(packet);
        const result = try hq_stage.afterRecount(self.stage, hq_stage.recount(&flags), story_castle_flag);
        self.stage = result.stage;
        return result;
    }

    pub fn recruit(self: *State, packet: hq_roster.source.Packet, windows: *const hq_windows.Asset, window: *const hq_windows.Window, facts: hq_windows.Facts, expected_revision: u64, option: ?u8, story_castle_flag: bool) !?hq_windows.Plan {
        return self.recruitImpl(packet, windows, window, facts, expected_revision, option, story_castle_flag, null);
    }

    pub fn recruitMapped(self: *State, packet: hq_roster.source.Packet, windows: *const hq_windows.Asset, window: *const hq_windows.Window, facts: hq_windows.Facts, expected_revision: u64, option: ?u8, story_castle_flag: bool, identities: *const RecruitIdentityMap) !?hq_windows.Plan {
        return self.recruitImpl(packet, windows, window, facts, expected_revision, option, story_castle_flag, identities);
    }

    fn recruitImpl(self: *State, packet: hq_roster.source.Packet, windows: *const hq_windows.Asset, window: *const hq_windows.Window, facts: hq_windows.Facts, expected_revision: u64, option: ?u8, story_castle_flag: bool, identities: ?*const RecruitIdentityMap) !?hq_windows.Plan {
        if (expected_revision != self.revision) return error.StaleBeforeState;
        const outcome = if (option) |choice| hq_windows.choose(window, choice, facts) else hq_windows.evaluate(window, facts);
        if (outcome.route != .admitted) return null;
        const plan = outcome.plan orelse return error.MissingRecruitmentPlan;
        const current = self.recruitFlags(packet);
        if ((current[plan.cid] & 1) != 0) return error.DuplicateRecruitment;
        const portrait = if (identities) |map| blk: {
            for (map.identities) |entry| {
                if (entry.recruit_id == plan.cid) break :blk entry.portrait_index;
            }
            return error.UnsupportedRecruitmentIdentity;
        } else blk: {
            const identity_row = hq_windows.identity(windows, plan.cid) orelse return error.UnsupportedRecruitmentIdentity;
            break :blk identity_row.portrait_index orelse return error.UnsupportedRecruitmentIdentity;
        };

        var next = self.*;
        next.identities = identities;
        try next.roster.apply(packet, .{ .recruit = .{ .identity = portrait, .recruited = true, .source_text = window.id } });
        next.revision = try std.math.add(u64, self.revision, 1);
        next.roster.revision = next.revision;
        next.roster.snapshot.baseline_revision = next.revision;
        const flags = next.recruitFlags(packet);
        next.stage = (try hq_stage.afterRecount(next.stage, hq_stage.recount(&flags), story_castle_flag)).stage;
        next.last_window = window.id;
        try next.roster.validate(packet);
        self.* = next;
        return plan;
    }

    pub fn capture(self: *const State, allocator: std.mem.Allocator) !Snapshot {
        return .{ .stage = self.stage, .revision = self.revision, .last_window = self.last_window, .roster_json = try self.roster.save(allocator) };
    }

    pub fn restore(allocator: std.mem.Allocator, packet: hq_roster.source.Packet, snapshot: Snapshot) !State {
        const roster = try hq_roster.roster.Roster.restore(allocator, packet, snapshot.roster_json);
        if (roster.revision != snapshot.revision) return error.InvalidRecruitmentSnapshot;
        return .{ .roster = roster, .stage = snapshot.stage, .revision = snapshot.revision, .last_window = snapshot.last_window };
    }

    pub fn restoreMapped(allocator: std.mem.Allocator, packet: hq_roster.source.Packet, snapshot: Snapshot, identities: *const RecruitIdentityMap) !State {
        var result = try restore(allocator, packet, snapshot);
        result.identities = identities;
        return result;
    }
};
