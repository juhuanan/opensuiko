//! Maps source seed facts into existing battle ownership only when every named
//! item, rune and profile has an explicit, compatible runtime representation.
const std = @import("std");
const character_state = @import("field").game_state;
const types = @import("battle_rules");
const field = @import("field");
const session = @import("session.zig");

pub const Item = struct {
    id: []const u8,
    uses: u16,
    slot: ?types.EquipmentSlot,
    locked: bool,
    identified: bool,
};
pub const Weapon = struct { level: u8, names: [16]?[]const u8, powers: [16]u16 };
pub const Seed = struct {
    hp: u16,
    max_hp: u16,
    level: u8,
    experience: u32,
    stats: [6]u16,
    status: ?enum { healthy },
    charges: [4]u16,
    inventory: []const Item,
    weapon: Weapon,
    rune_name: ?[]const u8,
    rune_source_id: u8,
    rune_unresolved: bool,
    rune_locked: bool,
    weapon_element: @FieldType(session.CharacterExtra, "weapon_element"),
    weapon_fragments: [5]u8,
};
pub const Character = struct { id: []const u8, name: []const u8, source_character_id: u32, resource: []const u8 = "", resource_sha256: []const u8 = "", growth: [6]u4, seed: Seed };
pub const Catalogue = struct { schema: []const u8, characters: []const Character };
pub const OwnershipBindings = struct {
    schema: []const u8,
    roster_content_sha256: []const u8,
    ted: struct { character_id: []const u8, source_character_id: u32, source_rune_id: u8, rune_id: []const u8, display_name: []const u8, locked: bool },
};
const binding_digest = "f969285b96ba396adb3f1cc9b0f2a2c2001662c5433b7b3c441db8847fbb7eb2";

/// The binding digest covers the exact D file bytes; its roster hash covers the
/// exact B file bytes. C's canonical-JSON hashes are a separate host check.
pub fn decodeBindings(allocator: std.mem.Allocator, bytes: []const u8, roster_bytes: []const u8) !std.json.Parsed(OwnershipBindings) {
    if (bytes.len > 64 * 1024 or roster_bytes.len > 1024 * 1024) return error.CatalogueTooLarge;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), binding_digest)) return error.InvalidBindings;
    const parsed = try std.json.parseFromSlice(OwnershipBindings, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    std.crypto.hash.sha2.Sha256.hash(roster_bytes, &hash, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), parsed.value.roster_content_sha256) or
        !std.mem.eql(u8, parsed.value.schema, "suikoden-magic-ownership-bindings/1") or
        !std.mem.eql(u8, parsed.value.ted.character_id, "ted") or parsed.value.ted.source_character_id != 108 or
        parsed.value.ted.source_rune_id != 32 or !std.mem.eql(u8, parsed.value.ted.rune_id, "masked_rune_32") or
        !std.mem.eql(u8, parsed.value.ted.display_name, "??????") or !parsed.value.ted.locked) return error.InvalidBindings;
    return parsed;
}
pub const Materialized = struct { owned: character_state.Character, extra: session.CharacterExtra };

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Catalogue) {
    if (bytes.len > 1024 * 1024) return error.CatalogueTooLarge;
    const parsed = try std.json.parseFromSlice(Catalogue, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema, "suikoden-party-source-facts/1") or parsed.value.characters.len != session.max_owned) return error.InvalidCatalogue;
    for (parsed.value.characters, 0..) |character, i| {
        if (character.id.len == 0 or character.name.len == 0) return error.InvalidCatalogue;
        for (parsed.value.characters[0..i]) |other| if (std.mem.eql(u8, character.id, other.id)) return error.InvalidCatalogue;
    }
    return parsed;
}

pub fn materialize(rules: character_state.CharacterRules, catalog: Catalogue, id: []const u8) !Materialized {
    return materializeBound(rules, catalog, id, null);
}
pub fn materializeBound(rules: character_state.CharacterRules, catalog: Catalogue, id: []const u8, bindings: ?OwnershipBindings) !Materialized {
    const character = for (catalog.characters) |candidate| {
        if (std.mem.eql(u8, candidate.id, id)) break candidate;
    } else return error.UnknownCharacter;
    const profile = rules.profile(id) orelse return error.ProfileUnavailable;
    const systems = rules.tables orelse return error.SystemsUnavailable;
    const seed = character.seed;
    if (!std.mem.eql(u8, profile.name, character.name) or !std.mem.eql(u4, &profile.growth, &character.growth) or profile.rune_locked != seed.rune_locked) return error.ProfileMismatch;
    const weapon = profile.weapon orelse return error.WeaponUnavailable;
    if (seed.weapon.level == 0 or seed.weapon.level > 16 or weapon.initial_level != seed.weapon.level or !std.mem.eql(u16, &weapon.powers, &seed.weapon.powers)) return error.WeaponMismatch;
    for (weapon.names, seed.weapon.names) |expected, actual| {
        if (expected.len == 0) return error.WeaponNameUnavailable;
        if (actual) |name| {
            if (!std.mem.eql(u8, expected, name)) return error.WeaponMismatch;
        }
    }
    if (seed.status == null or seed.inventory.len > 9) return error.UnsupportedSeed;
    var masked_rune: ?[]const u8 = null;
    if (seed.rune_unresolved) {
        const binding = bindings orelse return error.UnsupportedSeed;
        if (!std.mem.eql(u8, binding.schema, "suikoden-magic-ownership-bindings/1") or
            !std.mem.eql(u8, binding.roster_content_sha256, "32c43243829886c69de039789bb76cf3be1a630cfdb50fed5c19967bebeb948a") or
            !std.mem.eql(u8, binding.ted.character_id, "ted") or binding.ted.source_character_id != 108 or
            binding.ted.source_rune_id != 32 or !std.mem.eql(u8, binding.ted.rune_id, "masked_rune_32") or
            !std.mem.eql(u8, binding.ted.display_name, "??????") or !binding.ted.locked or
            !std.mem.eql(u8, character.id, binding.ted.character_id) or character.source_character_id != binding.ted.source_character_id or
            seed.rune_source_id != binding.ted.source_rune_id or !seed.rune_locked or
            profile.rune == null or !std.mem.eql(u8, profile.rune.?, binding.ted.rune_id)) return error.InvalidBindings;
        masked_rune = binding.ted.rune_id;
    }
    const base_attack = std.math.add(u16, seed.stats[0], weapon.powers[seed.weapon.level - 1]) catch return error.InvalidSeed;
    var owned: character_state.Character = .{
        .id = profile.id,
        .name = profile.name,
        .hp = seed.hp,
        .max_hp = seed.max_hp,
        .status = .healthy,
        .rune_charges = seed.charges,
        .max_rune_charges = @splat(0),
        .level = seed.level,
        .experience = seed.experience,
        .base_stats = .{ .attack = base_attack, .skill = seed.stats[1], .defense = seed.stats[2], .speed = seed.stats[3], .magic = seed.stats[4], .luck = seed.stats[5] },
        .weapon_level = seed.weapon.level,
        .loadout = .{},
        .rune = null,
    };
    var extra: session.CharacterExtra = .{ .member_id = profile.id, .weapon_element = seed.weapon_element, .weapon_fragments = seed.weapon_fragments };
    for (seed.inventory, 0..) |item, i| {
        const item_id = std.meta.stringToEnum(field.items.Id, item.id) orelse return error.ItemUnavailable;
        const uses: u16 = if (item_id.maxUses() == 0) 0 else if (item.uses == 0) item_id.maxUses() else item.uses;
        owned.inventory.slots[i] = .{ .id = item_id, .uses = uses, .identified = item.identified };
        if (item.slot) |slot| {
            var equipment: ?usize = null;
            for (systems.equipment, 0..) |entry, index| if (std.mem.eql(u8, entry.id, item.id)) {
                equipment = index;
                break;
            };
            if (equipment == null or owned.loadout.get(slot) != null) return error.EquipmentUnavailable;
            owned.loadout.set(slot, equipment);
            const index: usize = switch (slot) {
                .head => 0,
                .body => 1,
                .shield => 2,
                .accessory_one => 3,
                .accessory_two => 4,
            };
            extra.locked_equipment[index] = item.locked;
        } else if (item.locked) return error.UnsupportedSeed;
    }
    if (masked_rune) |rune_id| {
        for (systems.runes, 0..) |rune, i| if (std.mem.eql(u8, rune.id, rune_id)) {
            if (!std.mem.eql(u8, rune.name, "??????")) return error.InvalidBindings;
            owned.rune = i;
            break;
        };
        if (owned.rune == null) return error.RuneUnavailable;
    } else if (seed.rune_name) |name| {
        for (systems.runes, 0..) |rune, i| if (std.mem.eql(u8, rune.name, name)) {
            owned.rune = i;
            break;
        };
        if (owned.rune == null) return error.RuneUnavailable;
    }
    owned.max_rune_charges = owned.runeCapacity(systems);
    try rules.validate(owned);
    return .{ .owned = owned, .extra = extra };
}
