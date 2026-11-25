const std = @import("std");
const campaign = @import("chapters").final_map;
const data = @import("final_assets").recruitment_map;

const allocator = std.testing.allocator;

fn load() !campaign.Loaded {
    return campaign.open(allocator, data.json);
}

test "asset hash and complete Star alias census are pinned" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);

    var loaded = try load();
    defer loaded.deinit();
    const asset = loaded.parsed.value;
    try std.testing.expectEqual(@as(usize, 108), asset.identities.len);
    try std.testing.expectEqual(@as(usize, 309), asset.grant_sites.len);
    try std.testing.expectEqual(@as(u16, 108), asset.coverage.identities_with_grant_sites);
    try std.testing.expectEqual(@as(u16, 0), asset.coverage.identities_without_grant_sites);
    try std.testing.expectEqual(@as(u16, 75), asset.coverage.optional_windows);
    try std.testing.expectEqual(@as(u16, 73), asset.coverage.validated_optional_windows);
    try std.testing.expectEqual(@as(u16, 70), asset.coverage.validated_optional_sites);
    try std.testing.expectEqual(@as(u16, 2), asset.coverage.unmatched_optional_windows);

    const hero = campaign.identity(asset, 8).?;
    try std.testing.expectEqualStrings("Hero", hero.name);
    try std.testing.expectEqual(@as(u8, 0), hero.portrait_index);
    try std.testing.expectEqual(@as(u8, 8), hero.combat_record_id.?);
    const viktor = campaign.identity(asset, 35).?;
    try std.testing.expectEqualStrings("Viktor", viktor.name);
    try std.testing.expectEqual(@as(u8, 4), viktor.portrait_index);
    const mathiu = campaign.identity(asset, 27).?;
    try std.testing.expectEqualStrings("Mathiu", mathiu.name);
    try std.testing.expect(mathiu.combat_record_id == null);
    try std.testing.expect(campaign.identity(asset, 108) == null);
}

test "every identity grant reference resolves to the same recruit id" {
    var loaded = try load();
    defer loaded.deinit();
    const asset = loaded.parsed.value;
    for (asset.identities) |entry| {
        try std.testing.expect(entry.grant_site_ids.len != 0);
        for (entry.grant_site_ids) |id| {
            const site = campaign.grantSite(asset, id).?;
            try std.testing.expectEqual(entry.recruit_id, site.recruit_id);
            try std.testing.expectEqualStrings("source_only", site.runtime_state);
            try std.testing.expectEqualStrings("unresolved", site.campaign_order);
        }
    }
}

test "Maas retains independent source and optional-window identities" {
    var loaded = try load();
    defer loaded.deinit();
    const asset = loaded.parsed.value;
    const maas = campaign.identity(asset, 70).?;
    try std.testing.expectEqualStrings("Maas", maas.name);
    try std.testing.expect(maas.optional_window_ids.len != 0);
    var found = false;
    for (maas.grant_site_ids) |id| {
        const site = campaign.grantSite(asset, id).?;
        if (std.mem.eql(u8, site.source_file, "DATA/02_AREA.B/VB6.BIN") and
            site.opcode_offset == 0x35D19) found = true;
    }
    try std.testing.expect(found);
}

test "unmatched recruitment streams remain visible blockers" {
    var loaded = try load();
    defer loaded.deinit();
    const asset = loaded.parsed.value;
    try std.testing.expect(campaign.blocker(asset, "optional_windows_not_reached_from_listed_stream"));
    try std.testing.expect(campaign.blocker(asset, "chronology_unresolved"));
    try std.testing.expect(!campaign.blocker(asset, "recruitment_complete"));
}

test "stale and mismatched references fail closed" {
    var loaded = try load();
    defer loaded.deinit();
    var bad_schema = loaded.parsed.value;
    bad_schema.schema = "substituted";
    try std.testing.expectError(error.InvalidSchema, campaign.validate(bad_schema));

    var bad_reference = loaded.parsed.value;
    const identities = try allocator.dupe(campaign.Identity, bad_reference.identities);
    defer allocator.free(identities);
    const references = try allocator.dupe([]const u8, identities[0].grant_site_ids);
    defer allocator.free(references);
    references[0] = "missing";
    identities[0].grant_site_ids = references;
    bad_reference.identities = identities;
    try std.testing.expectError(error.MissingGrantReference, campaign.validate(bad_reference));

    var executable_claim = loaded.parsed.value;
    const sites = try allocator.dupe(campaign.GrantSite, executable_claim.grant_sites);
    defer allocator.free(sites);
    sites[0].runtime_state = "compiled";
    executable_claim.grant_sites = sites;
    try std.testing.expectError(error.UnsupportedProgressClaim, campaign.validate(executable_claim));
}
