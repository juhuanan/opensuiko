//! Static data: 78 source combat profiles, 108 identities, the
//! growth/weapon/rune/equipment tables and the twelve source roster
//! operations.  This file only parses and validates the asset; the ownership
//! ledger lives in `progression.zig`.
const std = @import("std");

pub const schema = "suikoden-final-roster-progression/1";
pub const state_schema = "suikoden-final-roster-state/1";
pub const profile_count = 78;
pub const identity_count = 108;
pub const guest_count = 2;
pub const equipment_count = 58;
pub const rune_count = 33;

pub const Inventory = struct {
    id: []const u8,
    uses: u16,
    slot: ?[]const u8,
    locked: bool,
    identified: bool,
};
pub const Weapon = struct {
    level: u8,
    names: [16]?[]const u8,
    powers: [16]u16,
};
pub const RuneSeed = struct {
    id: []const u8,
    source_id: u8,
    locked: bool,
    unresolved: bool,
};
pub const Seed = struct {
    hp: u16,
    max_hp: u16,
    level: u8,
    experience: u16,
    stats: [6]u16,
    charges: [4]u16,
    inventory: []const Inventory,
    weapon: Weapon,
    rune: ?RuneSeed,
    weapon_element: []const u8,
    weapon_fragments: [5]u8,
};
pub const Profile = struct {
    id: []const u8,
    name: []const u8,
    resource: []const u8,
    resource_sha256: []const u8,
    source_character_id: u16,
    identity: ?u16,
    growth: [6]u8,
    seed: Seed,
    allowed_equipment: []const []const u8,
};
pub const Identity = struct {
    index: u16,
    name: []const u8,
    combat_profile_id: ?[]const u8,
    recruit_id: u16,
    portrait_index: u16,
    tablet_entry: u16,
    grant_sites: u16,
    optional_windows: u16,
};
pub const Guest = struct {
    id: []const u8,
    name: []const u8,
    source_character_id: u16,
};
pub const Equipment = struct {
    id: []const u8,
    class: []const u8,
};
pub const Rune = struct {
    id: []const u8,
    name: []const u8,
    source_id: u8,
};
pub const UnmappedItem = struct {
    id: []const u8,
    source_item_id: u8,
    reason: []const u8,
};
pub const Operation = struct {
    id: []const u8,
    family: []const u8,
    preserve_member: bool,
};
pub const Retention = struct {
    operations: []const Operation,
    preserve: []const []const u8,
};
pub const Rules = struct {
    max_owned: u16,
    max_active: u8,
    active_min: u8,
    max_followers: u8,
    exp_per_level: u16,
    max_level: u8,
    weapon_max_level: u8,
    stat_rand_bits: u8,
    hp_rand_bits: u8,
    stat_table: [48]u32,
    hp_table: [48]u32,
    stat_tiers: [16][2]u8,
    hp_tiers: [2]u8,
    magic_thresholds: [4][9]u8,
    weapon_piece_limit: u8,
    weapon_piece_types: [5][]const u8,
};
pub const Coverage = struct {
    profiles: u16,
    identities: u16,
    bridged_identities: u16,
    noncombatant_identities: u16,
    guests: u16,
    seeded_runes: u16,
    weapon_curves: u16,
    equipment_catalog: u16,
    rune_catalog: u16,
    unmapped_items: u16,
    grant_sites: u16,
    optional_windows: u16,
    retention_operations: u16,
    profiles_with_allowed_equipment: u16,
};
pub const Blocker = struct {
    id: []const u8,
    detail: []const u8,
};
pub const Asset = struct {
    schema: []const u8,
    pack: []const u8,
    state_schema: []const u8,
    rules: Rules,
    profiles: []const Profile,
    identities: []const Identity,
    guests: []const Guest,
    equipment: []const Equipment,
    runes: []const Rune,
    unmapped_items: []const UnmappedItem,
    retention: Retention,
    coverage: Coverage,
    blockers: []const Blocker,
    content_sha256: []const u8,
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

pub fn profile(asset: Asset, id: []const u8) ?*const Profile {
    for (asset.profiles) |*entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}
pub fn identity(asset: Asset, index: u16) ?Identity {
    for (asset.identities) |entry| if (entry.index == index) return entry;
    return null;
}
pub fn guest(asset: Asset, id: []const u8) ?Guest {
    for (asset.guests) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}
pub fn equipment(asset: Asset, id: []const u8) ?Equipment {
    for (asset.equipment) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}
pub fn rune(asset: Asset, id: []const u8) ?Rune {
    for (asset.runes) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}
pub fn unmapped(asset: Asset, id: []const u8) ?UnmappedItem {
    for (asset.unmapped_items) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}
pub fn blocker(asset: Asset, id: []const u8) bool {
    for (asset.blockers) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}
pub fn operation(asset: Asset, id: []const u8) ?Operation {
    for (asset.retention.operations) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}
pub fn allows(asset: Asset, profile_id: []const u8, item: []const u8) bool {
    const entry = profile(asset, profile_id) orelse return false;
    for (entry.allowed_equipment) |candidate| if (std.mem.eql(u8, candidate, item)) return true;
    return false;
}
pub fn magicCapacity(asset: Asset, magic: u16) [4]u16 {
    var charges: [4]u16 = @splat(0);
    for (asset.rules.magic_thresholds, 0..) |row, tier| for (row) |threshold| {
        if (magic > threshold) charges[tier] += 1;
    };
    return charges;
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema)) return error.InvalidSchema;
    if (!std.mem.eql(u8, asset.state_schema, state_schema)) return error.InvalidStateSchema;
    if (!std.mem.eql(u8, asset.pack, "final_roster") or asset.content_sha256.len != 64) return error.InvalidIdentity;
    if (asset.profiles.len != profile_count or asset.identities.len != identity_count or
        asset.guests.len != guest_count or asset.equipment.len != equipment_count or
        asset.runes.len != rune_count or asset.unmapped_items.len != 2 or
        asset.blockers.len == 0) return error.InvalidCensus;
    if (asset.rules.max_owned != profile_count or asset.rules.max_active != 6 or
        asset.rules.active_min != 1 or asset.rules.max_followers != 6 or
        asset.rules.exp_per_level != 1000 or asset.rules.max_level != 99 or
        asset.rules.weapon_max_level != 16 or asset.rules.stat_rand_bits != 8 or
        asset.rules.hp_rand_bits != 9 or asset.rules.weapon_piece_limit != 9) return error.InvalidRules;
    for (asset.rules.stat_table) |value| if (value > 0xFFFF) return error.InvalidRules;
    for (asset.rules.hp_table) |value| if (value > 0xFFFF) return error.InvalidRules;
    for (asset.rules.stat_tiers) |row| if (row[0] >= row[1] or row[1] > 99) return error.InvalidRules;
    if (asset.rules.hp_tiers[0] >= asset.rules.hp_tiers[1] or asset.rules.hp_tiers[1] > 99) return error.InvalidRules;
    for (asset.rules.magic_thresholds) |row| for (row, 0..) |threshold, i| {
        if (i > 0 and threshold <= row[i - 1]) return error.InvalidRules;
    };
    const piece_names = [_][]const u8{ "fire", "water", "wind", "thunder", "earth" };
    for (piece_names, asset.rules.weapon_piece_types) |expected, actual| {
        if (!std.mem.eql(u8, expected, actual)) return error.InvalidRules;
    }

    var profiles_by_id: usize = 0;
    var identities_by_index: usize = 0;
    var bridged: usize = 0;
    for (asset.profiles, 0..) |entry, i| {
        if (entry.id.len == 0 or entry.name.len == 0 or entry.resource.len == 0 or entry.resource_sha256.len != 64) return error.InvalidProfile;
        if (entry.seed.level == 0 or entry.seed.level > 99 or entry.seed.experience >= 1000 or
            entry.seed.weapon.level == 0 or entry.seed.weapon.level > 16 or entry.seed.max_hp == 0 or
            entry.seed.hp > entry.seed.max_hp) return error.InvalidProfile;
        if (entry.seed.inventory.len > 9) return error.InvalidProfile;
        for (entry.growth) |rate| if (rate >= 16) return error.InvalidProfile;
        for (entry.seed.weapon.names) |maybe_name| if (maybe_name) |name| if (name.len == 0) return error.InvalidProfile;
        for (entry.seed.weapon.powers) |power| if (power == 0) return error.InvalidProfile;
        if (entry.identity) |index| {
            if (index >= identity_count) return error.InvalidProfile;
            bridged += 1;
        }
        for (asset.profiles[0..i]) |previous| {
            if (std.mem.eql(u8, previous.id, entry.id) or std.mem.eql(u8, previous.name, entry.name) or
                previous.source_character_id == entry.source_character_id) return error.DuplicateProfile;
        }
        profiles_by_id += 1;
        if (entry.seed.rune) |rune_seed| {
            if (rune_seed.id.len == 0) return error.InvalidProfile;
            const record = rune(asset, rune_seed.id) orelse return error.InvalidProfile;
            if (record.source_id != rune_seed.source_id) return error.InvalidProfile;
            if (rune_seed.locked and !rune_seed.unresolved and record.name.len == 0) return error.InvalidProfile;
        }
        for (entry.seed.inventory) |item| {
            if (item.id.len == 0 or item.uses > 99) return error.InvalidProfile;
        }
        for (entry.allowed_equipment) |item| {
            _ = equipment(asset, item) orelse return error.InvalidProfile;
        }
    }
    if (profiles_by_id != profile_count or bridged != 76) return error.InvalidCensus;
    for (asset.identities) |entry| {
        if (entry.index >= identity_count or entry.name.len == 0) return error.InvalidIdentity;
        if (entry.combat_profile_id) |id| {
            const record = profile(asset, id) orelse return error.InvalidIdentity;
            if (record.identity == null or record.identity.? != entry.index or
                !std.mem.eql(u8, record.id, entry.combat_profile_id.?)) return error.InvalidIdentity;
        }
        for (asset.identities[0..identities_by_index]) |previous| {
            if (previous.index == entry.index or std.mem.eql(u8, previous.name, entry.name)) return error.DuplicateIdentity;
        }
        identities_by_index += 1;
    }
    if (identities_by_index != identity_count) return error.InvalidCensus;
    for (asset.guests, 0..) |entry, i| {
        if (profile(asset, entry.id) == null or profile(asset, entry.id).?.identity != null) return error.InvalidGuest;
        if (!std.mem.eql(u8, entry.name, profile(asset, entry.id).?.name)) return error.InvalidGuest;
        for (asset.guests[0..i]) |previous| if (std.mem.eql(u8, previous.id, entry.id)) return error.DuplicateGuest;
    }
    for (asset.equipment, 0..) |entry, i| {
        if (!std.mem.eql(u8, entry.class, "head") and !std.mem.eql(u8, entry.class, "body") and
            !std.mem.eql(u8, entry.class, "shield") and !std.mem.eql(u8, entry.class, "accessory")) return error.InvalidEquipment;
        for (asset.equipment[0..i]) |previous| if (std.mem.eql(u8, previous.id, entry.id)) return error.DuplicateEquipment;
    }
    for (asset.runes, 0..) |entry, i| {
        if (entry.id.len == 0 or entry.source_id == 0 or entry.source_id > 33) return error.InvalidRune;
        for (asset.runes[0..i]) |previous| if (std.mem.eql(u8, previous.id, entry.id)) return error.DuplicateRune;
    }
    for (asset.unmapped_items, 0..) |entry, i| {
        if (entry.id.len == 0 or entry.reason.len == 0 or entry.source_item_id == 0) return error.InvalidUnmappedItem;
        for (asset.unmapped_items[0..i]) |previous| if (std.mem.eql(u8, previous.id, entry.id)) return error.DuplicateUnmappedItem;
    }
    if (asset.retention.operations.len != 12) return error.InvalidRetention;
    for (asset.retention.operations) |entry| {
        if (entry.id.len == 0 or entry.family.len == 0 or !entry.preserve_member) return error.InvalidRetention;
    }
    if (asset.coverage.profiles != profile_count or asset.coverage.identities != identity_count or
        asset.coverage.bridged_identities != 76 or asset.coverage.noncombatant_identities != 32 or
        asset.coverage.guests != guest_count or asset.coverage.weapon_curves != profile_count or
        asset.coverage.equipment_catalog != equipment_count or asset.coverage.rune_catalog != rune_count or
        asset.coverage.grant_sites != 309 or asset.coverage.optional_windows != 75 or
        asset.coverage.retention_operations != 12 or asset.coverage.seeded_runes != 22 or
        asset.coverage.unmapped_items != 2) return error.InvalidCoverage;
}
