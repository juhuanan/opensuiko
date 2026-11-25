const std = @import("std");
const battle_rules = @import("battle_rules");

pub const schema = "suikoden-opening-start/1";

pub const SourceEvidence = struct { path: []const u8, sha256: []const u8, schema: []const u8 };
pub const Location = struct { overlay_slot: u8, room_slot: u8 };
pub const Point = struct { x: i32, y: i32 };
pub const FieldEntry = struct { position: Point, camera: Point };
pub const Boot = struct {
    template_sha256: []const u8,
    scenario_sha256: []const u8,
    scenario_bytes: [240]u8,
    resource_slots: [6]u8,
    formation_order: [6]u8,
    money: u32,
    party_count: u8,
    party_slot_order: []const u8,
    location: Location,
    field_entry: FieldEntry,
};
pub const Item = struct { id: []const u8, uses: u8 };
pub const Equipped = struct {
    head: ?[]const u8 = null,
    body: ?[]const u8 = null,
    shield: ?[]const u8 = null,
    accessory_one: ?[]const u8 = null,
    accessory_two: ?[]const u8 = null,
};
pub const Stats = struct { power: u8, skill: u8, defense: u8, speed: u8, magic: u8, luck: u8 };
pub const Hero = struct {
    id: []const u8,
    native_character_id: u8,
    record_row: u8,
    active_slot: u8,
    level: u8,
    experience: u16,
    hp: u16,
    max_hp: u16,
    base_stats: Stats,
    inventory: []const Item,
    equipped: Equipped,
    weapon_level: u8,
    rune: ?[]const u8,
    rune_charges: [4]u8,
};
pub const NameContract = struct {
    accepted_buffer_address: u32,
    canonical_name_offset: u16,
    accepted_glyph_bytes: u8,
    terminator_offset: u16,
    copy_routine: u32,
    termination_routine: u32,
    new_game_init: u32,
    opening_stream_entry: u32,
    main_handoff: u32,
    copy_semantics: []const u8,
};
pub const RngContract = struct {
    bios_default_seed: u32,
    warmup_draws: u8,
    srand_wrapper: u32,
    rand_wrapper: u32,
    unused_root_counter_seed_helper: u32,
    helper_reference_state: []const u8,
    code_files_cross_checked: u16,
    draw_owner: []const u8,
};
pub const Producers = struct {
    name_entry_and_movie: []const u8,
    original_rng_seed_and_global_draw_order: []const u8,
    prototype_party_or_private_seed_allowed: bool,
};
pub const Asset = struct {
    schema: []const u8,
    status: []const u8,
    source_evidence: SourceEvidence,
    boot: Boot,
    hero: Hero,
    name_contract: NameContract,
    rng_contract: RngContract,
    producers: Producers,
    content_sha256: []const u8,
};

pub const RequestKind = enum { cancel, new_game, load };
pub const NewGamePlan = struct { draws: battle_rules.Draws };
pub const Decision = union(enum) {
    cancelled,
    load_requested: u8,
    invalid_slot: u8,
    start_new_game: NewGamePlan,
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
        return error.InvalidStartSchema;
    if (!std.mem.eql(u8, asset.source_evidence.schema, "suikoden-canonical-start-evidence/3") or
        asset.source_evidence.sha256.len != 64 or asset.boot.template_sha256.len != 64 or
        asset.boot.scenario_sha256.len != 64) return error.InvalidStartEvidence;
    if (asset.boot.money != 1500 or asset.boot.party_count != 1 or
        asset.boot.party_slot_order.len != 1 or asset.boot.party_slot_order[0] != 0 or
        asset.boot.location.overlay_slot != 9 or asset.boot.location.room_slot != 2 or
        asset.boot.field_entry.position.x != 512 or asset.boot.field_entry.position.y != 584 or
        asset.boot.field_entry.camera.x != 320 or asset.boot.field_entry.camera.y != 472)
        return error.InvalidStartBoot;
    var scenario_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&asset.boot.scenario_bytes, &scenario_digest, .{});
    if (!std.mem.allEqual(u8, &asset.boot.scenario_bytes, 0) or !std.mem.eql(u8, &std.fmt.bytesToHex(scenario_digest, .lower), asset.boot.scenario_sha256) or
        !std.mem.eql(u8, &asset.boot.resource_slots, &[_]u8{ 8, 255, 255, 255, 255, 255 }) or
        !std.mem.eql(u8, &asset.boot.formation_order, &[_]u8{ 0, 254, 254, 254, 254, 254 })) return error.InvalidStartBoot;
    const hero = asset.hero;
    if (!std.mem.eql(u8, hero.id, "hero") or hero.native_character_id != 8 or
        hero.record_row != 0 or hero.active_slot != 0 or hero.level != 1 or
        hero.experience != 0 or hero.hp != 17 or hero.max_hp != 17 or
        hero.weapon_level != 1 or hero.rune != null or
        !std.mem.eql(u8, &hero.rune_charges, &[_]u8{ 0, 0, 0, 0 }) or
        !std.meta.eql(hero.base_stats, .{ .power = 13, .skill = 22, .defense = 18, .speed = 15, .magic = 12, .luck = 15 }))
        return error.InvalidStartHero;
    if (hero.inventory.len != 5 or
        !std.mem.eql(u8, hero.inventory[0].id, "bandanna") or
        !std.mem.eql(u8, hero.inventory[1].id, "tunic") or
        !std.mem.eql(u8, hero.inventory[2].id, "gloves") or
        !std.mem.eql(u8, hero.inventory[3].id, "boots") or
        !std.mem.eql(u8, hero.inventory[4].id, "medicine") or hero.inventory[4].uses != 6)
        return error.InvalidStartInventory;
    const head = hero.equipped.head orelse return error.InvalidStartInventory;
    const body = hero.equipped.body orelse return error.InvalidStartInventory;
    const accessory_one = hero.equipped.accessory_one orelse return error.InvalidStartInventory;
    const accessory_two = hero.equipped.accessory_two orelse return error.InvalidStartInventory;
    if (!std.mem.eql(u8, head, "bandanna") or
        !std.mem.eql(u8, body, "tunic") or
        !std.mem.eql(u8, accessory_one, "gloves") or
        !std.mem.eql(u8, accessory_two, "boots") or hero.equipped.shield != null)
        return error.InvalidStartInventory;
    const contract = asset.name_contract;
    if (contract.accepted_buffer_address != 0x800A0300 or contract.canonical_name_offset != 0x1B74 or
        contract.accepted_glyph_bytes != 8 or contract.terminator_offset != 0x1B7C or
        contract.copy_routine != 0x80012450 or contract.termination_routine != 0x8001A8CC or
        contract.new_game_init != 0x80017544 or contract.opening_stream_entry != 0x80012294 or
        contract.main_handoff != 0x800166B8 or
        !std.mem.eql(u8, contract.copy_semantics, "copy_exactly_eight_accepted_glyphs_then_zero_terminate_byte_eight"))
        return error.InvalidNameContract;
    const rng = asset.rng_contract;
    if (rng.bios_default_seed != 1 or rng.warmup_draws != 0 or
        rng.srand_wrapper != 0x80147D38 or rng.rand_wrapper != 0x80147E38 or
        rng.unused_root_counter_seed_helper != 0x80126058 or
        !std.mem.eql(u8, rng.helper_reference_state, "no_direct_call_pointer_literal_or_fallthrough") or
        rng.code_files_cross_checked != 346 or !std.mem.eql(u8, rng.draw_owner, "shared_bios_a0_2f_stream"))
        return error.InvalidRngContract;
    if (!std.mem.eql(u8, asset.producers.name_entry_and_movie, "source_backed_slus_name_copy_stream_and_main_handoff") or
        !std.mem.eql(u8, asset.producers.original_rng_seed_and_global_draw_order, "source_backed_bios_default_seed_1_shared_a0_2f_draw_order") or
        asset.producers.prototype_party_or_private_seed_allowed)
        return error.UnsupportedStartProducerClaim;
}

pub fn copyAcceptedName(source: [8]u8) [9]u8 {
    var result = std.mem.zeroes([9]u8);
    result[0..8].* = source;
    return result;
}

pub fn plan(asset: Asset, kind: RequestKind, slot: u8, ready: [3]bool) !Decision {
    try validate(asset);
    return switch (kind) {
        .cancel => .cancelled,
        .new_game => .{ .start_new_game = .{ .draws = .{ .bios_state = asset.rng_contract.bios_default_seed } } },
        .load => if (slot < ready.len and ready[slot])
            .{ .load_requested = slot }
        else
            .{ .invalid_slot = slot },
    };
}
