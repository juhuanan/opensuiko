const std = @import("std");

pub const schema = "suikoden-middle-battles/1";

pub const FormationSource = struct { file: []const u8, lba: u32, size: u32, sha256: []const u8 };
pub const Slot = struct {
    slot: u8,
    enemy_id: u8,
    stats_offset: ?u32,
    flags: ?u16,
    world: ?[3]i32,
    world_q12: ?[3]i32,
    aux_offset: ?u32 = null,
};
pub const Formation = struct {
    id: []const u8,
    source_file: []const u8,
    region: u8,
    descriptor_offset: u32,
    auxiliary_offset: u32,
    positions_offset: ?u32,
    roster: [6]u8,
    slots: []const Slot,
    policy_state: []const u8,
};
pub const Entry = struct {
    id: []const u8,
    source_file: []const u8,
    room: u8,
    entity_ids: []const u8,
    stream: u32,
    offset: u32,
    selector: u8,
    formation_id: ?[]const u8,
    entry_state: []const u8,
    victory: []const u8,
    defeat: []const u8,
    escape: []const u8,
    runtime_state: []const u8,
};
pub const Coverage = struct {
    formations: u16,
    entries: u16,
    resolved_entries: u16,
    unresolved_entries: u16,
    reviewed_formations: u16,
    source_only_formations: u16,
    production_entries: u16,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    formation_sources: []const FormationSource,
    formations: []const Formation,
    entries: []const Entry,
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

fn knownSource(asset: Asset, path: []const u8) bool {
    for (asset.formation_sources) |source| {
        if (std.mem.eql(u8, source.file, path)) return true;
    }
    return false;
}

pub fn formationById(asset: Asset, id: []const u8) ?Formation {
    for (asset.formations) |formation| {
        if (std.mem.eql(u8, formation.id, id)) return formation;
    }
    return null;
}

pub fn entryAt(asset: Asset, stream: u32) ?Entry {
    for (asset.entries) |entry| {
        if (entry.stream == stream) return entry;
    }
    return null;
}

pub fn entryByOffset(asset: Asset, offset: u32) ?Entry {
    for (asset.entries) |entry| {
        if (entry.offset == offset) return entry;
    }
    return null;
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64)
        return error.InvalidBattleSchema;
    const coverage = asset.coverage;
    if (asset.formations.len != 90 or asset.entries.len != 50 or
        coverage.formations != 90 or coverage.entries != 50 or coverage.resolved_entries != 50 or
        coverage.unresolved_entries != 0 or coverage.reviewed_formations != 77 or
        coverage.source_only_formations != 13 or coverage.production_entries != 0)
        return error.InvalidBattleCoverage;
    for (asset.formations, 0..) |formation, index| {
        if (!knownSource(asset, formation.source_file) or formation.roster.len != 6 or
            formation.slots.len == 0) return error.InvalidBattleFormation;
        for (asset.formations[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, formation.id)) return error.DuplicateBattleFormation;
        }
        for (formation.slots) |slot| if (slot.enemy_id == 0) return error.InvalidBattleFormation;
    }
    for (asset.entries, 0..) |entry, index| {
        if (entry.entity_ids.len == 0 or entry.formation_id == null or
            !std.mem.eql(u8, entry.entry_state, "source_entry") or
            !std.mem.eql(u8, entry.runtime_state, "source_only") or
            !std.mem.eql(u8, entry.victory, "return_to_source_stream_no_auto_chain") or
            !std.mem.eql(u8, entry.defeat, "game_over_not_victory") or
            !std.mem.eql(u8, entry.escape, "typed_blocker_source_retry_unresolved"))
            return error.InvalidBattleEntry;
        if (formationById(asset, entry.formation_id.?) == null) return error.MissingBattleFormation;
        for (asset.entries[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, entry.id) or
                (std.mem.eql(u8, earlier.source_file, entry.source_file) and
                    earlier.room == entry.room and earlier.stream == entry.stream and earlier.offset == entry.offset))
                return error.DuplicateBattleEntry;
        }
    }
}
