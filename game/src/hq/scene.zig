//! Headquarters construction: source stages, rooms, actors and doorways.
//!
//! The catalogue is compiled from the disc by the extraction pipeline.
//! It carries, for each accepted HQ stage (0..4):
//!
//!   * the castle area file and the mirror landing room (room 2 at half-cell
//!     (14,15), the accepted tier record);
//!   * the area's 16-byte room records with their section extents and the
//!     shared ground/population asset ids;
//!   * every 24-byte entity record as an actor with its source flags, resource
//!     binding and classification predicate;
//!   * every proved doorway as an inclusive half-cell rectangle plus the inline
//!     room transition that ends its stream.
//!
//! The module is a *construction* rule, not a renderer: actors are the shared
//! `suikoden-scene-population/1` records and ground is the shared
//! `suikoden-field-ground-geometry/1` asset. Nothing here paints, allocates,
//! dispatches an event or mutates gameplay state.
//!
//! Presence is evaluated against borrowed host facts: the shared
//! `event_runtime.StoryState` scenario bytes, the canonical recruit-flag block
//! (`gs+0x1AF4` bytes), the active party order, persistent levels and the stage-plan
//! stage byte. An actor spawns only when it is a population candidate, every
//! classification term has a proved source semantic and evaluates true, and its
//! bound resource exists. Anything else — a random predicate, sampled input, an
//! unknown level, a missing resource — cannot spawn.
//!
//! The condition vocabulary extends the shared `scene_population.Term` set
//! (which currently carries story masks plus an `unsupported` tag). Keeping the
//! HQ-specific extension here is deliberately a single small switch, not a
//! second VM.

const std = @import("std");
const validation = @import("validation");
const event_runtime = @import("event_runtime");
const stage_mod = @import("stage.zig");
const shared = @import("scene_population");

pub const schema = "suikoden-hq-stage-scenes/1";
pub const stage_domain: u8 = 5;
pub const flag_slots: usize = 108;
pub const party_slots: usize = 6;
pub const level_slots: usize = 256;
pub const scenario_bytes: usize = 240;
pub const snapshot_magic = "HQSCN001";
pub const snapshot_version: u8 = 1;
pub const snapshot_size: usize = 8 + 1 + 1 + 2 + scenario_bytes + flag_slots + party_slots + level_slots;

pub const Placement = enum { placed, unpositioned, off_map_staging, not_applicable };
pub const Direction = enum { up, right, down, left };
pub const Role = enum { character, event, initialization };
pub const Trigger = enum { ordinary, interaction, area_entry, initialization };
pub const Domain = enum { area_character_context, active_party_character };

/// The headquarters presence term is the shared `scene_population.HqTerm`; the
/// truth table lives in the shared owner so this builder and the area
/// population owner cannot drift apart.
pub const Term = shared.HqTerm;

pub const Position = struct {
    source_x: u16,
    source_y: u16,
    x: u16,
    y: u16,
};

pub const Resource = struct {
    domain: Domain,
    key: []const u8,
    context_record: ?u32 = null,
    context_index: ?u8 = null,
    binding_index: ?u8 = null,
};

pub const Actor = struct {
    id: []const u8,
    room: u8,
    entity_index: u8,
    record_role: Role,
    source_flags: u16,
    population_candidate: bool,
    source_character_id: ?u16 = null,
    resource: ?Resource = null,
    position: Position,
    classification: []const Term = &.{},
    classification_proved: bool = false,
    trigger: Trigger = .ordinary,
    initialization_order: ?u8 = null,
    placement: Placement = .not_applicable,
};

pub const Room = struct {
    id: []const u8,
    index: u8,
    section: u16,
    record_offset: u32,
    record_flags: u16 = 0,
    variant_record: bool = false,
    width_tiles: u16,
    height_tiles: u16,
    width_cells: u16,
    height_cells: u16,
    entity_count: u8,
    scenery_count: u16,
    actor_ids: []const []const u8,
    entrance_ids: []const []const u8,
    reachable: bool,
    materialized: bool,
    ground_id: ?[]const u8 = null,
    population_id: ?[]const u8 = null,
    primary_map_offset: ?u32 = null,
    secondary_map_offset: ?u32 = null,
    secondary_section: ?u8 = null,
};

pub const Bounds = struct { x: u16, y: u16, w: u16, h: u16 };

pub const Destination = struct {
    room: u8,
    source_x: u16,
    source_y: u16,
    x: u16,
    y: u16,
    domain: []const u8,
};

pub const Entrance = struct {
    id: []const u8,
    room: u8,
    entity_index: u8,
    bounds: Bounds,
    direction: ?Direction = null,
    mask: ?u16 = null,
    interaction_required: bool = false,
    conditions: []const Term = &.{},
    proved: bool,
    destination: Destination,
};

pub const ServiceActor = struct {
    id: []const u8,
    room: u8 = 0,
    source_character_id: ?u16 = null,
    resource_key: ?[]const u8 = null,
    placement: Placement = .not_applicable,
    classification: []const Term = &.{},
    classification_proved: bool = false,
    service_family: ?[]const u8 = null,
    binding_status: []const u8 = "",
};

pub const Landing = struct {
    room: u8,
    source_x: u16,
    source_y: u16,
    x: u16,
    y: u16,
    identity: []const u8,
    reachable: bool = true,
};

pub const Area = struct {
    file: []const u8,
    lba: u32,
    size: u32,
    sha256: []const u8,
};

pub const StageSource = struct {
    path: []const u8,
    sha256: []const u8,
    schema: []const u8,
    table: []const u8,
    bytes: []const u8,
};

pub const StageEntry = struct {
    stage: u8,
    mirror_area_index: u8,
    castle_area_slot: ?u8 = null,
    area: Area,
    landing: Landing,
    rooms: []const Room,
    actors: []const Actor,
    entrances: []const Entrance,
    service_actors: []const ServiceActor = &.{},
};

pub const Catalogue = struct {
    schema: []const u8,
    id: []const u8,
    content_sha256: []const u8,
    stage_source: StageSource,
    stages: []const StageEntry,
};

pub const max_json_bytes = 8 * 1024 * 1024;
pub const max_room_index = 255;

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Catalogue) {
    if (bytes.len > max_json_bytes) return error.CatalogueTooLarge;
    const parsed = try std.json.parseFromSlice(Catalogue, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

fn validId(id: []const u8) bool {
    return validation.isUtf8Text(id, 1, 96);
}

pub fn validate(catalogue: Catalogue) !void {
    if (!std.mem.eql(u8, catalogue.schema, schema)) return error.UnsupportedCatalogueSchema;
    if (!validId(catalogue.id)) return error.InvalidCatalogue;
    if (catalogue.content_sha256.len != 64 or !validId(catalogue.stage_source.path)) return error.InvalidCatalogue;
    if (catalogue.stage_source.sha256.len != 64) return error.InvalidCatalogue;
    if (!std.mem.eql(u8, catalogue.stage_source.schema, "suikoden-hq-stage-plan/1")) return error.InvalidCatalogue;
    if (catalogue.stages.len == 0 or catalogue.stages.len > stage_domain) return error.InvalidCatalogue;

    var seen_stage: [stage_domain]bool = @splat(false);
    for (catalogue.stages) |entry| {
        if (entry.stage >= stage_domain) return error.InvalidStage;
        if (seen_stage[entry.stage]) return error.DuplicateStage;
        seen_stage[entry.stage] = true;
        if (entry.mirror_area_index != stage_mod.mirror_areas[entry.stage]) return error.InvalidStage;
        const stage_value = try stage_mod.Stage.fromByte(entry.stage);
        if (entry.castle_area_slot != stage_value.castleAreaSlot()) return error.InvalidStage;
        if (!validId(entry.area.file) or entry.area.size == 0 or entry.area.sha256.len != 64) return error.InvalidStage;
        if (!validId(entry.landing.identity)) return error.InvalidStage;
        if (entry.rooms.len == 0 or entry.rooms.len > max_room_index) return error.InvalidRooms;
        if (entry.actors.len == 0 or entry.entrances.len == 0) return error.InvalidStage;

        // Rooms: unique identity, unique area room index, consistent extent, and
        // every actor/entrance reference resolvable inside this stage.
        var landing_seen = false;
        for (entry.rooms, 0..) |room, room_pos| {
            if (!validId(room.id)) return error.InvalidRoom;
            if (room.width_tiles == 0 or room.height_tiles == 0 or room.width_tiles > 256 or room.height_tiles > 256) return error.InvalidRoom;
            if (room.width_cells != room.width_tiles * 2 or room.height_cells != room.height_tiles * 2) return error.InvalidRoom;
            if (room.materialized != room.reachable) return error.InvalidRoom;
            if (room.materialized and ((room.population_id == null) != (room.entity_count == 0))) return error.InvalidRoom;
            if (room.materialized and room.ground_id == null) return error.InvalidRoom;
            if (!room.materialized and (room.ground_id != null or room.population_id != null)) return error.InvalidRoom;
            if (room.index == entry.landing.room) {
                landing_seen = true;
                if (!room.materialized) return error.InvalidRoom;
            }
            for (entry.rooms[0..room_pos]) |other| {
                if (std.mem.eql(u8, room.id, other.id) or room.index == other.index) return error.DuplicateRoom;
            }
            if (room.actor_ids.len != room.entity_count) return error.InvalidRoom;
            for (room.actor_ids) |actor_id| {
                const actor = findActor(entry, actor_id) orelse return error.UnknownActorReference;
                if (actor.room != room.index) return error.UnknownActorReference;
            }
            for (room.entrance_ids) |entrance_id| {
                const entrance = findEntrance(entry, entrance_id) orelse return error.UnknownEntranceReference;
                if (entrance.room != room.index) return error.InvalidRoom;
            }
        }
        if (!landing_seen) return error.InvalidStage;

        for (entry.actors, 0..) |actor, actor_pos| {
            if (!validId(actor.id)) return error.InvalidActor;
            if (findRoom(entry, actor.room) == null) return error.InvalidActor;
            const character = actor.record_role == .character;
            if (character) {
                if (actor.source_character_id == null or actor.source_character_id.? == 0) return error.InvalidActor;
                const resource = actor.resource orelse return error.InvalidActor;
                if (!validId(resource.key)) return error.InvalidActor;
                if (resource.domain == .area_character_context and resource.context_record == null) return error.InvalidActor;
                if (actor.initialization_order != null or actor.trigger == .initialization) return error.InvalidActor;
            } else {
                if (actor.source_character_id != null or actor.resource != null or actor.population_candidate) return error.InvalidActor;
                if (actor.placement != .not_applicable) return error.InvalidActor;
            }
            if (actor.position.source_x > 255 or actor.position.source_y > 255) return error.InvalidActor;
            if (actor.position.x != actor.position.source_x * 8 or actor.position.y != actor.position.source_y * 8) return error.InvalidActor;
            for (entry.actors[0..actor_pos]) |other| {
                if (std.mem.eql(u8, actor.id, other.id)) return error.DuplicateActor;
            }
            try validateTerms(actor.classification, actor.classification_proved);
            if (actor.record_role == .initialization and actor.trigger != .initialization) return error.InvalidActor;
        }

        for (entry.entrances, 0..) |entrance, entrance_pos| {
            if (!validId(entrance.id)) return error.InvalidEntrance;
            if (findRoom(entry, entrance.room) == null) return error.InvalidEntrance;
            if (findRoom(entry, entrance.destination.room) == null) return error.InvalidEntrance;
            if (entrance.destination.source_x > 255 or entrance.destination.source_y > 255) return error.InvalidEntrance;
            if (!std.mem.eql(u8, entrance.destination.domain, "half_cell")) return error.InvalidEntrance;
            if (entrance.bounds.w == 0 or entrance.bounds.h == 0) return error.InvalidEntrance;
            try validateTerms(entrance.conditions, entrance.proved);
            for (entry.entrances[0..entrance_pos]) |other| {
                if (std.mem.eql(u8, entrance.id, other.id)) return error.DuplicateEntrance;
            }
        }

        for (entry.service_actors) |service| {
            const actor = findActor(entry, service.id) orelse return error.UnknownActorReference;
            if (actor.trigger != .interaction or !actor.population_candidate) return error.InvalidActor;
            if (service.binding_status.len == 0) return error.InvalidActor;
            if (service.service_family != null) return error.InvalidActor;
        }
    }
}

fn validateTerms(terms: []const Term, proved: bool) !void {
    for (terms) |term| try shared.validateHqTerm(term);
    if (proved != shared.hqTermsProved(terms)) return error.InvalidTerm;
}

pub fn findStage(catalogue: Catalogue, stage: stage_mod.Stage) ?*const StageEntry {
    for (catalogue.stages) |*entry| {
        if (entry.stage == stage.byte()) return entry;
    }
    return null;
}

pub fn findRoom(entry: StageEntry, index: u8) ?*const Room {
    for (entry.rooms) |*room| {
        if (room.index == index) return room;
    }
    return null;
}

pub fn findActor(entry: StageEntry, id: []const u8) ?*const Actor {
    for (entry.actors) |*actor| {
        if (std.mem.eql(u8, actor.id, id)) return actor;
    }
    return null;
}

pub fn findEntrance(entry: StageEntry, id: []const u8) ?*const Entrance {
    for (entry.entrances) |*entrance| {
        if (std.mem.eql(u8, entrance.id, id)) return entrance;
    }
    return null;
}

// --- facts -----------------------------------------------------------------

pub const Roster = struct {
    /// The 108 canonical recruit bytes (`gs+0x1AF4`): bit0 recruited, bit1 removed.
    recruit: *const [flag_slots]u8,
    /// Active party source character ids, in party order.
    party: []const u8,
    /// Persistent level by source character id; 0 means unknown.
    levels: *const [level_slots]u8,
};

pub const Facts = struct {
    stage: stage_mod.Stage,
    story: *const event_runtime.StoryState,
    roster: Roster,
};

/// One save-shaped slice of the construction inputs. The host owns the real
/// save; this type exists so a rebuild can prove condition/identity retention.
pub const State = struct {
    stage_byte: u8 = 0,
    story: event_runtime.StoryState = .{},
    recruit: [flag_slots]u8 = @splat(0),
    party: [party_slots]u8 = @splat(0),
    party_len: u8 = 0,
    levels: [level_slots]u8 = @splat(0),

    pub fn facts(self: *State) !Facts {
        const stage = try stage_mod.Stage.fromByte(self.stage_byte);
        return .{
            .stage = stage,
            .story = &self.story,
            .roster = .{
                .recruit = &self.recruit,
                .party = self.party[0..self.party_len],
                .levels = &self.levels,
            },
        };
    }

    pub fn setParty(self: *State, ids: []const u8) !void {
        if (ids.len > party_slots) return error.PartyTooLarge;
        self.party = @splat(0);
        @memcpy(self.party[0..ids.len], ids);
        self.party_len = @intCast(ids.len);
    }

    pub fn recruitByte(self: *const State, slot: u8) u8 {
        return if (slot < flag_slots) self.recruit[slot] else 0;
    }

    pub fn setRecruit(self: *State, slot: u8, byte: u8) !void {
        if (slot >= flag_slots) return error.InvalidRecruitSlot;
        if (byte & 0xFC != 0) return error.InvalidRecruitByte;
        self.recruit[slot] = byte;
    }

    pub fn encode(self: *const State) [snapshot_size]u8 {
        var out: [snapshot_size]u8 = @splat(0);
        @memcpy(out[0..8], snapshot_magic);
        out[8] = snapshot_version;
        out[9] = self.stage_byte;
        out[10] = self.party_len;
        @memcpy(out[12..252], &self.story.scenario);
        @memcpy(out[252..360], &self.recruit);
        @memcpy(out[360..366], &self.party);
        @memcpy(out[366..622], &self.levels);
        return out;
    }

    pub fn decode(bytes: []const u8) !State {
        if (bytes.len != snapshot_size) return error.InvalidSnapshotLength;
        if (!std.mem.eql(u8, bytes[0..8], snapshot_magic)) return error.InvalidSnapshotMagic;
        if (bytes[8] != snapshot_version) return error.UnsupportedSnapshotVersion;
        var state: State = .{};
        state.stage_byte = bytes[9];
        if (state.stage_byte >= stage_domain) return error.InvalidStage;
        state.party_len = bytes[10];
        if (state.party_len > party_slots) return error.InvalidParty;
        if (bytes[11] != 0) return error.TamperedSnapshot;
        @memcpy(&state.story.scenario, bytes[12..252]);
        @memcpy(&state.recruit, bytes[252..360]);
        @memcpy(&state.party, bytes[360..366]);
        @memcpy(&state.levels, bytes[366..622]);
        for (state.recruit) |byte| if (byte & 0xFC != 0) return error.TamperedSnapshot;
        for (state.party, 0..) |id, index| {
            if (index >= state.party_len and id != 0) return error.TamperedSnapshot;
        }
        return state;
    }
};

// --- presence --------------------------------------------------------------

/// Evaluate a conjunction of proven terms through the shared headquarters
/// truth table. A term whose fact is unavailable (unknown level) or whose
/// semantic is unproved returns false: no default.
pub fn evaluate(terms: []const Term, facts: Facts) bool {
    return shared.hqTermsSatisfied(terms, .{
        .stage = facts.stage.byte(),
        .story = facts.story,
        .roster = .{
            .recruit = facts.roster.recruit,
            .party = facts.roster.party,
            .levels = facts.roster.levels,
        },
    });
}

// --- reconstruction --------------------------------------------------------

pub const RoomView = struct {
    id: []const u8,
    index: u8,
    width_cells: u16,
    height_cells: u16,
    landing: bool,
    actor_count: u16,
    entrance_count: u16,
};

pub const ActorView = struct {
    id: []const u8,
    room: u8,
    entity_index: u8,
    source_character_id: u16,
    resource_key: []const u8,
    placement: Placement,
    x: u16,
    y: u16,
};

pub const Construction = struct {
    stage: stage_mod.Stage,
    rooms: []const RoomView,
    actors: []const ActorView,
    skipped_unproved_actors: u16,
    skipped_unproved_entrances: u16,
};

fn placementFor(position: Position, room: *const Room) Placement {
    if (0 < position.source_x and position.source_x < room.width_cells and
        0 < position.source_y and position.source_y < room.height_cells)
    {
        return .placed;
    }
    if (position.source_x == 0 and position.source_y == 0) return .unpositioned;
    return .off_map_staging;
}

/// Reconstruct the current headquarters: reachable rooms in catalogue order and
/// the actors that the current story/roster proves. Rooms are reached from the
/// landing through proved doorways whose conditions hold; an unproved doorway is
/// skipped, never assumed open. Unproved actors are skipped, never defaulted.
pub fn reconstruct(
    catalogue: *const Catalogue,
    facts: Facts,
    room_out: []RoomView,
    actor_out: []ActorView,
) !Construction {
    const entry = findStage(catalogue.*, facts.stage) orelse return error.UnknownStage;
    var reachable: [max_room_index + 1]bool = @splat(false);
    reachable[entry.landing.room] = true;

    var skipped_unproved_entrances: u16 = 0;
    for (entry.entrances) |entrance| {
        if (!entrance.proved) skipped_unproved_entrances += 1;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (entry.entrances) |entrance| {
            if (!entrance.proved) continue;
            if (!reachable[entrance.room]) continue;
            if (reachable[entrance.destination.room]) continue;
            if (!evaluate(entrance.conditions, facts)) continue;
            reachable[entrance.destination.room] = true;
            changed = true;
        }
    }

    var room_count: usize = 0;
    for (entry.rooms) |*room| {
        if (!reachable[room.index]) continue;
        if (!room.materialized) return error.UnmaterializedReachableRoom;
        if (room_count == room_out.len) return error.RoomOutputTooSmall;
        var actor_count: u16 = 0;
        for (entry.actors) |*actor| {
            if (actor.room != room.index) continue;
            if (reachable_actor(actor, facts)) actor_count += 1;
        }
        room_out[room_count] = .{
            .id = room.id,
            .index = room.index,
            .width_cells = room.width_cells,
            .height_cells = room.height_cells,
            .landing = room.index == entry.landing.room,
            .actor_count = actor_count,
            .entrance_count = @intCast(room.entrance_ids.len),
        };
        room_count += 1;
    }

    var actor_count: usize = 0;
    var skipped_unproved_actors: u16 = 0;
    for (entry.actors) |*actor| {
        if (!reachable[actor.room]) continue;
        if (!actor.population_candidate) continue;
        if (!actor.classification_proved) {
            skipped_unproved_actors += 1;
            continue;
        }
        if (!evaluate(actor.classification, facts)) continue;
        const resource = actor.resource orelse return error.MissingResource;
        const room = findRoom(entry.*, actor.room) orelse return error.InvalidActor;
        if (actor_count == actor_out.len) return error.ActorOutputTooSmall;
        actor_out[actor_count] = .{
            .id = actor.id,
            .room = actor.room,
            .entity_index = actor.entity_index,
            .source_character_id = actor.source_character_id.?,
            .resource_key = resource.key,
            .placement = placementFor(actor.position, room),
            .x = actor.position.x,
            .y = actor.position.y,
        };
        actor_count += 1;
    }

    return .{
        .stage = facts.stage,
        .rooms = room_out[0..room_count],
        .actors = actor_out[0..actor_count],
        .skipped_unproved_actors = skipped_unproved_actors,
        .skipped_unproved_entrances = skipped_unproved_entrances,
    };
}

fn reachable_actor(actor: *const Actor, facts: Facts) bool {
    if (!actor.population_candidate) return false;
    if (!actor.classification_proved) return false;
    return evaluate(actor.classification, facts);
}
