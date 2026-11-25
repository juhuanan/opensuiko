const std = @import("std");

pub const schema = "suikoden-campaign-recruitment-map/1";
pub const star_count = 108;

pub const Identity = struct {
    recruit_id: u8,
    name: []const u8,
    portrait_index: u8,
    tablet_entry: u8,
    combat_record_id: ?u8,
    optional_window_ids: []const []const u8,
    grant_site_ids: []const []const u8,
    source_state: []const u8,
    campaign_order: []const u8,
    implementation_state: []const u8,
};

pub const GrantSite = struct {
    id: []const u8,
    recruit_id: u8,
    source_file: []const u8,
    room: u8,
    room_record: u32,
    stream: u32,
    opcode_offset: u32,
    selection: []const u8,
    optional_window_ids: []const []const u8,
    campaign_order: []const u8,
    runtime_state: []const u8,
};

pub const Coverage = struct {
    identities: u16,
    identities_with_grant_sites: u16,
    identities_without_grant_sites: u16,
    optional_windows: u16,
    validated_optional_windows: u16,
    validated_optional_sites: u16,
    unmatched_optional_windows: u16,
    optional_identities: u16,
    grant_sites: u16,
    story_or_forced_source_only_sites: u16,
    source_files: u16,
    chronology_resolved: u16,
    compiled_identities: u16,
};

pub const Blocker = struct { id: []const u8 };

pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    identities: []const Identity,
    grant_sites: []const GrantSite,
    coverage: Coverage,
    blockers: []const Blocker,
};

pub const Loaded = struct {
    parsed: std.json.Parsed(Asset),

    pub fn deinit(self: Loaded) void {
        self.parsed.deinit();
    }
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !Loaded {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return .{ .parsed = parsed };
}

pub fn identity(asset: Asset, recruit_id: u8) ?Identity {
    if (recruit_id >= asset.identities.len) return null;
    const result = asset.identities[recruit_id];
    return if (result.recruit_id == recruit_id) result else null;
}

pub fn grantSite(asset: Asset, id: []const u8) ?GrantSite {
    for (asset.grant_sites) |site| {
        if (std.mem.eql(u8, site.id, id)) return site;
    }
    return null;
}

pub fn blocker(asset: Asset, id: []const u8) bool {
    for (asset.blockers) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return true;
    }
    return false;
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema)) return error.InvalidSchema;
    if (asset.content_sha256.len != 64) return error.InvalidDigest;
    if (asset.identities.len != star_count or asset.coverage.identities != star_count)
        return error.InvalidIdentityCensus;
    if (asset.grant_sites.len != asset.coverage.grant_sites or
        asset.identities.len != asset.coverage.identities_with_grant_sites +
            asset.coverage.identities_without_grant_sites)
        return error.InvalidCoverage;

    var portraits = std.mem.zeroes([star_count]bool);
    var tablet_entries = std.mem.zeroes([star_count]bool);
    var combat_records = std.mem.zeroes([256]bool);
    var mapped_identities: usize = 0;
    for (asset.identities, 0..) |entry, index| {
        if (entry.recruit_id != index or entry.name.len == 0) return error.InvalidIdentity;
        if (entry.portrait_index >= star_count or portraits[entry.portrait_index] or
            entry.tablet_entry >= star_count or tablet_entries[entry.tablet_entry])
            return error.InvalidIdentityAlias;
        portraits[entry.portrait_index] = true;
        tablet_entries[entry.tablet_entry] = true;
        if (entry.combat_record_id) |record_id| {
            if (combat_records[record_id]) return error.DuplicateCombatRecord;
            combat_records[record_id] = true;
        }
        if (!std.mem.eql(u8, entry.campaign_order, "unresolved") or
            !std.mem.eql(u8, entry.implementation_state, "not_compiled"))
            return error.UnsupportedProgressClaim;
        if (entry.grant_site_ids.len == 0) {
            if (!std.mem.eql(u8, entry.source_state, "source_unresolved")) return error.InvalidIdentityState;
        } else {
            if (!std.mem.eql(u8, entry.source_state, "recovered")) return error.InvalidIdentityState;
            mapped_identities += 1;
        }
        for (entry.grant_site_ids) |id| {
            const site = grantSite(asset, id) orelse return error.MissingGrantReference;
            if (site.recruit_id != entry.recruit_id) return error.MismatchedGrantReference;
        }
    }
    if (mapped_identities != asset.coverage.identities_with_grant_sites)
        return error.InvalidCoverage;

    var optional_sites: usize = 0;
    var optional_windows: usize = 0;
    for (asset.grant_sites, 0..) |site, index| {
        if (site.recruit_id >= star_count or site.source_file.len == 0 or site.id.len == 0)
            return error.InvalidGrantSite;
        for (asset.grant_sites[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, site.id)) return error.DuplicateGrantSite;
        }
        if (!std.mem.eql(u8, site.campaign_order, "unresolved") or
            !std.mem.eql(u8, site.runtime_state, "source_only"))
            return error.UnsupportedProgressClaim;
        const optional = site.optional_window_ids.len != 0;
        if (optional) {
            optional_sites += 1;
            for (site.optional_window_ids, 0..) |window_id, window_index| {
                var seen = false;
                for (asset.grant_sites[0..index]) |earlier| {
                    for (earlier.optional_window_ids) |prior| {
                        if (std.mem.eql(u8, prior, window_id)) seen = true;
                    }
                }
                for (site.optional_window_ids[0..window_index]) |prior| {
                    if (std.mem.eql(u8, prior, window_id)) seen = true;
                }
                if (!seen) optional_windows += 1;
            }
            if (!std.mem.eql(u8, site.selection, "optional_window"))
                return error.InvalidGrantSelection;
        } else if (!std.mem.eql(u8, site.selection, "story_or_forced_source_only")) {
            return error.InvalidGrantSelection;
        }
    }
    if (optional_sites != asset.coverage.validated_optional_sites or
        optional_windows != asset.coverage.validated_optional_windows or
        asset.coverage.optional_windows != asset.coverage.validated_optional_windows +
            asset.coverage.unmatched_optional_windows or
        asset.grant_sites.len - optional_sites != asset.coverage.story_or_forced_source_only_sites)
        return error.InvalidCoverage;
    if (asset.coverage.chronology_resolved != 0 or asset.coverage.compiled_identities != 0)
        return error.UnsupportedProgressClaim;
}
