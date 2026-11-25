//! Migration of the established save families into the campaign envelope.
//!
//! Supported sources (exact keys are re-checked against the owning Zig struct
//! by the extraction pipeline):
//!
//!   suikoden-world-session/1..10  (world_session_save.Snapshot)
//!   suikoden-journey-save/1..6    (journey.Snapshot)
//!   suikoden-save/1..3            -> refused: no level/experience/weapon fields
//!
//! A migration is only accepted when every mapped field has an exact target.
//! Two legacy facts are content-local *indices*, not ids: the equipped-gear
//! slot and the rune slot index into `battle.Content.systems`, whose ordered
//! array is a build artifact and not tracked knowledge at this base.  The
//! caller may pass a `Bindings` value (the production owner has the battle
//! content) to resolve them; without it a save that carries gear is refused
//! rather than silently dropped.  The HQ sidecar needs the HQ roster
//! catalogue and is always refused here, as is an active boat/teleport session.

const std = @import("std");
const ids = @import("ids.zig");
const content = @import("content.zig");
const schema = @import("schema.zig");

pub const Source = enum { world_session, journey };

/// Resolves a content-local slot index to the id string the current content
/// knows.  Supplied by the owner of the ordered battle systems array.
pub const IndexSpace = struct {
    ctx: *const anyopaque,
    id_for_index: *const fn (ctx: *const anyopaque, index: usize) ?[]const u8,
};

pub const Bindings = struct {
    equipment: IndexSpace,
    rune: IndexSpace,
};

pub const Migration = struct {
    snapshot: schema.Snapshot,
    source: Source,
};

fn directionIndex(name: []const u8) !u8 {
    if (std.mem.eql(u8, name, "down")) return 0;
    if (std.mem.eql(u8, name, "up")) return 1;
    if (std.mem.eql(u8, name, "left")) return 2;
    if (std.mem.eql(u8, name, "right")) return 3;
    return error.LegacyFieldMissing;
}

fn parseId(comptime n: usize, text: []const u8) !ids.Id(n) {
    return ids.Id(n).init(text) catch return error.LegacyFieldMissing;
}

const LegacyStack = struct {
    id: []const u8,
    uses: u16 = 0,
    identified: bool = true,
};

const LegacyInventory = struct {
    slots: [9]?LegacyStack = @splat(null),
};

const LegacyMember = struct {
    id: []const u8,
    hp: u16,
    max_hp: u16,
    status: []const u8,
    rune_charges: [4]u16 = @splat(0),
    max_rune_charges: [4]u16 = @splat(0),
    inventory: ?LegacyInventory = null,
};

const Loadout = struct {
    head: ?usize = null,
    body: ?usize = null,
    shield: ?usize = null,
    accessory_one: ?usize = null,
    accessory_two: ?usize = null,
};

const gear_slots = 5;

fn loadoutSlot(loadout: Loadout, slot: usize) ?usize {
    return switch (slot) {
        0 => loadout.head,
        1 => loadout.body,
        2 => loadout.shield,
        3 => loadout.accessory_one,
        4 => loadout.accessory_two,
        else => null,
    };
}

const LegacyOwned = struct {
    member: LegacyMember,
    level: u8,
    experience: u32,
    weapon_level: u8,
    loadout: ?Loadout = null,
    rune: ?usize = null,
};

const LegacyStory = struct {
    scenario: ?struct { scenario: [240]u8 } = null,
};

const LegacyJourney = struct {
    schema: []const u8,
    room: []const u8,
    x: i32,
    y: i32,
    facing: []const u8,
    money: u32,
    story: LegacyStory,
    party: [6]LegacyMember,
    levels: [6]u8,
    experience: [6]u32,
    weapon_levels: ?[6]u8 = null,
    equipment: ?[6]?usize = null,
    loadouts: ?[6]Loadout = null,
    runes: ?[6]?usize = null,
    reserves: ?[72]?LegacyOwned = null,
    elapsed_ticks: ?u64 = null,
};

const LegacyCheckpointState = struct {
    mode: []const u8,
    camera: struct { x: i32, y: i32 },
    heading: []const u8 = "down",
};

const LegacyPosition = struct {
    schema: []const u8 = "suikoden-world-checkpoint/3",
    state: LegacyCheckpointState,
    region: []const u8,
};

const LegacyCampaign = struct {
    mode: []const u8 = "none",
    boat_ledger_json: ?[]const u8 = null,
    boat_session_json: ?[]const u8 = null,
    teleport_json: ?[]const u8 = null,
};

const LegacyWorldSession = struct {
    schema: []const u8,
    ownership: LegacyJourney,
    position: LegacyPosition,
    campaign: ?LegacyCampaign = null,
    hq: ?std.json.Value = null,
};

pub fn migrate(arena: std.mem.Allocator, value: std.json.Value, content_ref: *const content.Content) !Migration {
    return migrateValue(arena, value, content_ref, null);
}

pub fn detect(schema_name: []const u8) ?Source {
    if (std.mem.startsWith(u8, schema_name, "suikoden-world-session/")) return .world_session;
    if (std.mem.startsWith(u8, schema_name, "suikoden-journey-save/")) return .journey;
    return null;
}

/// Migrate a decoded legacy document.  `value` must be the whole file object.
pub fn migrateValue(arena: std.mem.Allocator, value: std.json.Value, content_ref: *const content.Content, bindings: ?Bindings) !Migration {
    if (value != .object) return error.LegacyFieldMissing;
    const schema_field = value.object.get("schema") orelse return error.LegacyFieldMissing;
    if (schema_field != .string) return error.LegacyFieldMissing;
    const source = detect(schema_field.string) orelse {
        if (std.mem.startsWith(u8, schema_field.string, "suikoden-save/")) return error.LegacyFormatUnsupported;
        return error.UnsupportedCampaignSchema;
    };
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    var snapshot: schema.Snapshot = undefined;
    switch (source) {
        .world_session => {
            const legacy = try std.json.innerParseFromValue(LegacyWorldSession, arena, value, options);
            if (!supportedWorldSession(legacy.schema)) return error.LegacySchemaUnsupported;
            snapshot = try migrateWorldSession(legacy, content_ref, bindings);
        },
        .journey => {
            const legacy = try std.json.innerParseFromValue(LegacyJourney, arena, value, options);
            if (!supportedJourney(legacy.schema)) return error.LegacySchemaUnsupported;
            snapshot = try migrateJourney(legacy, content_ref, bindings);
        },
    }
    // The old envelope had no campaign transaction, so nothing can be pending.
    snapshot.pending = null;
    snapshot.revision = 0;
    snapshot.last_receipt = 0;
    try snapshot.validate(content_ref);
    return .{ .snapshot = snapshot, .source = source };
}

fn supportedWorldSession(name: []const u8) bool {
    const version = std.fmt.parseInt(u8, name["suikoden-world-session/".len..], 10) catch return false;
    return version >= 1 and version <= 10;
}

fn supportedJourney(name: []const u8) bool {
    const version = std.fmt.parseInt(u8, name["suikoden-journey-save/".len..], 10) catch return false;
    return version >= 1 and version <= 16;
}

fn migrateWorldSession(legacy: LegacyWorldSession, content_ref: *const content.Content, bindings: ?Bindings) !schema.Snapshot {
    if (legacy.hq != null) return error.LegacyHqSidecarUnbound;
    if (legacy.campaign) |campaign| {
        if (!std.mem.eql(u8, campaign.mode, "none") or campaign.boat_ledger_json != null or campaign.boat_session_json != null or campaign.teleport_json != null) return error.LegacyTravelSessionActive;
    }
    if (!supportedJourney(legacy.ownership.schema)) return error.LegacySchemaUnsupported;
    const mode = legacy.position.state.mode;
    const field = std.mem.eql(u8, mode, "field");
    if (!field and !std.mem.eql(u8, mode, "world")) return error.LegacyBusyMode;
    const map_place = content_ref.place(try parseId(32, legacy.position.region)) orelse return error.LegacyWorldUnbound;
    if (map_place.kind != .map) return error.LegacyWorldUnbound;
    var snapshot = try baseSnapshot(content_ref, map_place.block, map_place.id, legacy.ownership, bindings);
    snapshot.world.camera_x = legacy.position.state.camera.x;
    snapshot.world.camera_y = legacy.position.state.camera.y;
    if (field) {
        const room_place = content_ref.place(try parseId(32, legacy.ownership.room)) orelse return error.LegacyRoomUnbound;
        if (room_place.kind != .room or !std.meta.eql(room_place.block, map_place.block)) return error.LegacyRoomUnbound;
        snapshot.world.room = room_place.id;
        snapshot.world.x = legacy.ownership.x;
        snapshot.world.y = legacy.ownership.y;
        snapshot.world.facing = try directionIndex(legacy.ownership.facing);
        snapshot.mode.kind = .field;
    } else {
        snapshot.world.facing = try directionIndex(legacy.position.state.heading);
    }
    return snapshot;
}

fn migrateJourney(legacy: LegacyJourney, content_ref: *const content.Content, bindings: ?Bindings) !schema.Snapshot {
    const room_place = content_ref.place(try parseId(32, legacy.room)) orelse return error.LegacyRoomUnbound;
    if (room_place.kind != .room) return error.LegacyRoomUnbound;
    const map = (try mapForBlock(content_ref, room_place.block)) orelse ids.Id(32){};
    var snapshot = try baseSnapshot(content_ref, room_place.block, map, legacy, bindings);
    snapshot.world.room = room_place.id;
    snapshot.world.x = legacy.x;
    snapshot.world.y = legacy.y;
    snapshot.world.facing = try directionIndex(legacy.facing);
    snapshot.mode.kind = .field;
    return snapshot;
}

/// The world map a field room belongs to, when the content names exactly one.
/// A canonical-opening room has no world-map place, and the schema allows an
/// empty map for a field save.
fn mapForBlock(content_ref: *const content.Content, block: ids.Id(32)) !?ids.Id(32) {
    var found: ?ids.Id(32) = null;
    for (content_ref.doc.places) |place| {
        if (place.kind != .map or !std.meta.eql(place.block, block)) continue;
        if (found != null) return error.LegacyWorldUnbound;
        found = place.id;
    }
    return found;
}

fn baseSnapshot(content_ref: *const content.Content, block: ids.Id(32), map: ids.Id(32), legacy: LegacyJourney, bindings: ?Bindings) !schema.Snapshot {
    var snapshot: schema.Snapshot = .{
        .content = content_ref.ref(),
        .saved_ticks = legacy.elapsed_ticks orelse 0,
        .quest = .{ .block = block, .money = legacy.money },
        .world = .{ .block = block, .map = map },
        .hq = .{ .stage = content_ref.doc.hq_stages[0] },
        .mode = .{ .kind = .world },
    };
    if (legacy.story.scenario) |story| snapshot.quest.scenario.bytes = story.scenario;
    try fillRoster(&snapshot, legacy, content_ref, bindings);
    return snapshot;
}

fn fillRoster(snapshot: *schema.Snapshot, legacy: LegacyJourney, content_ref: *const content.Content, bindings: ?Bindings) !void {
    for (0..6) |index| {
        const party = legacy.party[index];
        if (party.id.len == 0) continue;
        const id = try parseId(32, party.id);
        if (snapshot.roster.party.contains(id)) return error.LegacyDuplicateMember;
        var gear: [gear_slots]?usize = @splat(null);
        if (legacy.loadouts) |loadouts| {
            for (0..gear_slots) |slot| gear[slot] = loadoutSlot(loadouts[index], slot);
        } else if (legacy.equipment) |equipment| {
            gear[0] = equipment[index];
        }
        const rune = if (legacy.runes) |runes| runes[index] else null;
        const member = try mapMember(party, legacy.levels[index], legacy.experience[index], if (legacy.weapon_levels) |levels| levels[index] else 1, gear, rune, content_ref, bindings);
        if (snapshot.roster.members.len == snapshot.roster.members.items.len) return error.LegacyDuplicateMember;
        try snapshot.roster.members.append(member);
        try snapshot.roster.party.append(id);
    }
    if (legacy.reserves) |reserves| {
        for (reserves) |maybe| {
            const owned = maybe orelse continue;
            if (owned.member.id.len == 0) continue;
            const id = try parseId(32, owned.member.id);
            if (snapshot.roster.party.contains(id)) return error.LegacyDuplicateMember;
            if (snapshot.roster.reserves.contains(id)) return error.LegacyDuplicateMember;
            var gear: [gear_slots]?usize = @splat(null);
            if (owned.loadout) |loadout| {
                for (0..gear_slots) |slot| gear[slot] = loadoutSlot(loadout, slot);
            }
            const member = try mapMember(owned.member, owned.level, owned.experience, owned.weapon_level, gear, owned.rune, content_ref, bindings);
            try snapshot.roster.members.append(member);
            try snapshot.roster.reserves.append(id);
        }
    }
}

fn mapMember(legacy: LegacyMember, level: u8, experience: u32, weapon_level: u8, gear: [gear_slots]?usize, rune: ?usize, content_ref: *const content.Content, bindings: ?Bindings) !schema.Member {
    var member: schema.Member = .{
        .id = try parseId(32, legacy.id),
        .level = if (level == 0) 1 else level,
        .experience = experience,
        .hp = legacy.hp,
        .max_hp = legacy.max_hp,
        .weapon_level = weapon_level,
        .status = std.meta.stringToEnum(schema.Status, legacy.status) orelse return error.LegacyUnknownStatus,
        .rune_charges = legacy.rune_charges,
        .max_rune_charges = legacy.max_rune_charges,
    };
    if (!content_ref.hasRoster(member.id)) return error.LegacyFieldMissing;
    if (legacy.inventory) |inventory| {
        for (inventory.slots) |maybe| {
            const stack = maybe orelse continue;
            const id = try parseId(32, stack.id);
            if (!content_ref.hasItem(id)) return error.LegacyItemUnbound;
            try member.inventory.append(.{ .id = id, .uses = stack.uses });
        }
    }
    for (gear) |maybe| {
        const index = maybe orelse continue;
        const space = if (bindings) |value| value.equipment else return error.LegacyGearUnbound;
        const resolved = try resolveIndex(space, index);
        if (!content_ref.hasEquipment(resolved)) return error.LegacyGearUnbound;
        try member.equipment.append(resolved);
    }
    if (rune) |index| {
        const space = if (bindings) |value| value.rune else return error.LegacyGearUnbound;
        const resolved = try resolveIndex(space, index);
        if (!content_ref.hasRune(resolved)) return error.LegacyGearUnbound;
        member.rune = resolved;
    }
    return member;
}

fn resolveIndex(space: IndexSpace, index: usize) !ids.Id(32) {
    if (index > 255) return error.LegacyGearIndexOutOfRange;
    const name = space.id_for_index(space.ctx, index) orelse return error.LegacyGearIndexOutOfRange;
    return parseId(32, name);
}
