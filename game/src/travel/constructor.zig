//! Construct ordinary source populations with retained identity.
//!
//! The packet in the embedded campaign asset is produced by
//! the extraction pipeline from static source facts.  This module is the
//! runtime seam: it validates the qualified actor/resource bindings, constructs
//! the shared `field_actors` engine state from a construction-time story
//! snapshot, and resolves ordinary scene selectors through the compact slot
//! table.  A construction slot is deliberately not a source entity index.
//!
//! No allocation, event admission, movement, field/world dispatch or save
//! publication happens here except the JSON parse the caller asked for.
//! `Opened` borrows the caller's `Loaded` rows for its lifetime.

const std = @import("std");
const validation = @import("validation");
const field_actors = @import("field_actors");
const event_runtime = @import("event_runtime");
const motion = @import("opening_audience");

pub const schema = "suikoden-populations/1";
pub const story_schema = "suikoden-event-story/1";
pub const max_scenes = 8;
pub const max_records = 255;

pub const Domain = enum { area_character_context, active_party_character };

pub const Term = struct {
    kind: enum { story_mask_set, story_mask_clear, interaction, unsupported },
    flag: ?event_runtime.Flag = null,
    semantics: ?[]const u8 = null,
};

pub const Record = struct {
    entity: u16,
    kind: enum { unconditional, conditional, alias },
    slot: ?u16 = null,
    alias_slot: ?u16 = null,
    character_id: ?u16 = null,
    resource: ?[]const u8 = null,
    resource_domain: ?Domain = null,
    graphic: ?[]const u8 = null,
    conditions: []const Term = &.{},
    event_conditions: []const Term = &.{},
    source_flags: u16,
};

pub const Source = struct {
    file: []const u8,
    lba: u32,
    size: u32,
    sha256: []const u8,
    room: u8,
};

pub const Accepted = struct {
    population_file_sha256: []const u8,
    binding_file_sha256: []const u8,
    event_file_sha256: []const u8,
    actor_source_file_sha256: []const u8,
    actor_source_content_sha256: []const u8,
    animation_file_sha256: ?[]const u8 = null,
};

pub const AreaResource = struct {
    id: []const u8,
    character_id: u16,
    context: u32,
    record: u32,
    context_index: u32,
};

pub const LoadedRequirement = struct {
    character_id: u8,
    resource: []const u8,
    graphic: []const u8,
};

pub const SceneData = struct {
    id: []const u8,
    source: Source,
    population_sha256: []const u8,
    binding_sha256: []const u8,
    event_sha256: []const u8,
    accepted: Accepted,
    capacity: u16,
    area_resources: []const AreaResource,
    loaded_requirements: []const LoadedRequirement,
    records: []const Record,
    packet: field_actors.Packet,
    animations: []const motion.Animation,
    provenance: std.json.Value = .null,
};

pub const Contract = struct {
    compact_slots: []const u8,
    classification: []const u8,
    resource_domains: []const u8,
    loaded_party: []const u8,
    selectors: []const u8,
    identity: []const u8,
};

pub const SourceSet = struct {
    main_image_sha256: []const u8,
    files: std.json.Value,
};

pub const Asset = struct {
    schema: []const u8,
    target: []const u8,
    source: SourceSet,
    contract: Contract,
    scenes: []const SceneData,
    content_sha256: []const u8,
};

pub const LoadedEntry = struct {
    character_id: u8,
    resource: []const u8,
    graphic: []const u8,
};

pub const Loaded = struct {
    entries: []const LoadedEntry,
};

pub const SlotState = enum { active, reserved, released, not_constructed };

pub const SlotActor = struct {
    slot: u8,
    actor: *motion.Avatar,
    id: []const u8,
    entity: u16,
    character_id: u16,
    resource: []const u8,
    domain: Domain,
    graphic: []const u8,
};

pub const Resolution = union(enum) {
    hero: struct { character_id: u8 = 8 },
    slot: SlotActor,
};

pub const Retention = struct {
    fingerprint: [32]u8,
    would_rebuild_change: bool,
};

pub const Opened = struct {
    parsed: std.json.Parsed(Asset),
    scene_index: usize,
    loaded: Loaded,
    state: field_actors.State,

    pub fn deinit(self: *Opened) void {
        self.parsed.deinit();
    }

    pub fn scene(self: *const Opened) *const SceneData {
        return &self.parsed.value.scenes[self.scene_index];
    }

    pub fn recordForEntity(self: *const Opened, entity: u16) ?*const Record {
        const source = self.scene();
        for (source.records) |*record| if (record.entity == entity) return record;
        return null;
    }

    /// Returns the compact slot for a non-alias source record; a null
    /// classification record only exposes its alias, never an actor slot.
    pub fn slotForEntity(self: *const Opened, entity: u16) !u16 {
        const record = self.recordForEntity(entity) orelse return error.UnknownPopulationEntity;
        if (record.kind == .alias) return error.NullClassificationAlias;
        return record.slot.?;
    }

    pub fn slotState(self: *const Opened, slot: u16) SlotState {
        const source = self.scene();
        if (slot >= source.packet.actors.len) return .not_constructed;
        return switch (self.state.slots[slot].?.phase) {
            .active => .active,
            .absent => .reserved,
            .released => .released,
        };
    }

    /// 0x80 is the fixed hero descriptor.  Values below 0x40 are compact scene
    /// slots; 0x40..0x7f is the dynamic/temporary family and stays typed
    /// unsupported in this pack.
    pub fn resolveSelector(self: *Opened, selector: u8) !Resolution {
        const source = self.scene();
        try self.state.validate(source.packet, source.animations);
        if (selector == 0x80) return .{ .hero = .{} };
        if (selector & 0x40 != 0) return error.UnsupportedSelectorForm;
        if (selector >= source.packet.actors.len) return error.SelectorNotConstructed;
        const state_slot = &self.state.slots[selector].?;
        return switch (state_slot.phase) {
            .active => blk: {
                const avatar = &state_slot.avatar.?;
                const record = self.recordForSlot(selector) orelse return error.InvalidPopulationRecord;
                const definition = source.packet.actors[selector];
                break :blk .{ .slot = .{
                    .slot = selector,
                    .actor = avatar,
                    .id = definition.id,
                    .entity = definition.entity,
                    .character_id = record.character_id.?,
                    .resource = definition.resource,
                    .domain = record.resource_domain.?,
                    .graphic = definition.graphic,
                } };
            },
            .absent => error.SelectorNotConstructed,
            .released => error.SelectorReleased,
        };
    }

    fn recordForSlot(self: *const Opened, slot: u16) ?*const Record {
        for (self.scene().records) |*record| {
            if (record.kind != .alias and record.slot.? == slot) return record;
        }
        return null;
    }

    /// Marks one constructed actor released through the shared engine.  A real
    /// rebuild is the only operation that can construct it again.
    pub fn release(self: *Opened, actor_id: []const u8) !void {
        const source = self.scene();
        for (source.packet.actors) |definition| {
            if (!std.mem.eql(u8, definition.id, actor_id)) continue;
            self.state.release(source.packet, definition.id) catch |err| switch (err) {
                error.FieldActorNotConstructed => return error.ActorNotConstructed,
                error.FieldActorReleased => return error.ActorAlreadyReleased,
                else => return err,
            };
            return;
        }
        return error.UnknownPopulationActor;
    }

    /// A current-story change is not a reconstruction.  The live fingerprint is
    /// retained; `would_rebuild_change` only reports whether an explicit rebuild
    /// would select a different construction result.
    pub fn retainAfterStoryChange(self: *Opened, current: event_runtime.StoryState) !Retention {
        const source = self.scene();
        try self.state.validate(source.packet, source.animations);
        var changed = false;
        for (source.packet.actors) |definition| {
            if (self.state.construction_story.matches(definition.conditions) != current.matches(definition.conditions)) {
                changed = true;
                break;
            }
        }
        return .{ .fingerprint = self.fingerprint(), .would_rebuild_change = changed };
    }

    /// Real reconstruction: the retained release markers are gone and the new
    /// construction snapshot decides which compact slots are active or reserved.
    pub fn rebuild(self: *Opened, story: event_runtime.StoryState) !void {
        self.state = try constructScene(self.scene(), self.loaded, story);
    }

    pub fn fingerprint(self: *const Opened) [32]u8 {
        const source = self.scene();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(source.packet.content_sha256);
        hasher.update(&self.state.construction_story.scenario);
        var buffer2: [2]u8 = undefined;
        std.mem.writeInt(u16, &buffer2, @intCast(self.state.count), .little);
        hasher.update(&buffer2);
        var buffer: [4]u8 = undefined;
        for (self.state.slots[0..self.state.count]) |entry| {
            const slot = entry.?;
            hasher.update(&.{@backingInt(slot.phase)});
            if (slot.avatar) |avatar| {
                hasher.update(avatar.id);
                hasher.update(avatar.graphic);
                std.mem.writeInt(i32, &buffer, avatar.motion.x, .little);
                hasher.update(&buffer);
                std.mem.writeInt(i32, &buffer, avatar.motion.y, .little);
                hasher.update(&buffer);
                hasher.update(&.{
                    avatar.variant,
                    avatar.motion.speed,
                    @intFromBool(avatar.released),
                    @intCast(avatar.orientation_flags),
                });
            }
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
};

fn validId(id: []const u8) bool {
    return validation.isAsciiId(id, 96, "_");
}

fn validHash(hash: []const u8) bool {
    return validation.isHex64(hash);
}

fn scenarioIndex(id: []const u8) ?u8 {
    if (id.len != 13 or !std.mem.startsWith(u8, id, "scenario_")) return null;
    const value = std.fmt.parseInt(u16, id[9..], 10) catch return null;
    if (value >= 240) return null;
    return @intCast(value);
}

fn validateTerms(terms: []const Term) !void {
    for (terms) |term| switch (term.kind) {
        .story_mask_set, .story_mask_clear => {
            const flag = term.flag orelse return error.InvalidPopulationCondition;
            if (term.semantics != null or flag.mask == 0 or scenarioIndex(flag.id) == null) return error.InvalidPopulationCondition;
        },
        .interaction => if (term.flag != null or term.semantics != null) return error.InvalidPopulationCondition,
        .unsupported => {
            if (term.flag != null) return error.InvalidPopulationCondition;
            const semantics = term.semantics orelse return error.InvalidPopulationCondition;
            if (semantics.len == 0 or semantics.len > 64) return error.InvalidPopulationCondition;
        },
    };
}

fn sameCondition(term: Term, condition: event_runtime.Condition) bool {
    const flag = term.flag orelse return false;
    const kind_matches = switch (term.kind) {
        .story_mask_set => condition.kind == .story_mask_set,
        .story_mask_clear => condition.kind == .story_mask_clear,
        else => false,
    };
    return kind_matches and std.mem.eql(u8, flag.id, condition.flag.id) and flag.mask == condition.flag.mask;
}

fn hasAreaResource(scene_data: *const SceneData, resource: []const u8, character: u16) bool {
    for (scene_data.area_resources) |entry| {
        if (std.mem.eql(u8, entry.id, resource) and entry.character_id == character) return true;
    }
    return false;
}

fn hasLoadedRequirement(scene_data: *const SceneData, record: *const Record) bool {
    const resource = record.resource orelse return false;
    const graphic = record.graphic orelse return false;
    const character = record.character_id orelse return false;
    for (scene_data.loaded_requirements) |entry| {
        if (entry.character_id == character and std.mem.eql(u8, entry.resource, resource) and std.mem.eql(u8, entry.graphic, graphic)) return true;
    }
    return false;
}

fn validateScene(scene_data: *const SceneData) !void {
    if (!validId(scene_data.id) or scene_data.capacity == 0 or scene_data.capacity > 64) return error.InvalidPopulationScene;
    if (scene_data.source.file.len == 0 or scene_data.source.size == 0 or !validHash(scene_data.source.sha256)) return error.InvalidPopulationSource;
    if (!validHash(scene_data.population_sha256) or !validHash(scene_data.binding_sha256) or !validHash(scene_data.event_sha256)) return error.InvalidPopulationBinding;
    if (!validHash(scene_data.accepted.population_file_sha256) or !validHash(scene_data.accepted.binding_file_sha256) or
        !validHash(scene_data.accepted.event_file_sha256) or !validHash(scene_data.accepted.actor_source_file_sha256) or
        !validHash(scene_data.accepted.actor_source_content_sha256)) return error.InvalidPopulationAccepted;
    if (scene_data.accepted.animation_file_sha256) |hash| if (!validHash(hash)) return error.InvalidPopulationAccepted;

    try scene_data.packet.validate(scene_data.animations);
    if (!std.mem.eql(u8, scene_data.packet.scene, scene_data.id)) return error.PopulationSceneMismatch;
    if (!std.mem.eql(u8, scene_data.packet.population_sha256, scene_data.population_sha256) or
        !std.mem.eql(u8, scene_data.packet.binding_sha256, scene_data.binding_sha256) or
        !std.mem.eql(u8, scene_data.packet.event_sha256, scene_data.event_sha256)) return error.PopulationBindingMismatch;
    if (scene_data.capacity != scene_data.packet.actors.len or scene_data.capacity > 64) return error.InvalidPopulationCapacity;
    if (scene_data.records.len == 0 or scene_data.records.len > max_records) return error.InvalidPopulationRecords;
    if (scene_data.animations.len == 0) return error.InvalidPopulationAnimations;

    if (scene_data.area_resources.len > 255 or scene_data.loaded_requirements.len > 255) return error.InvalidPopulationBinding;
    for (scene_data.area_resources, 0..) |entry, index| {
        if (!validId(entry.id) or entry.character_id == 0 or entry.context == 0) return error.InvalidPopulationResource;
        for (scene_data.area_resources[0..index]) |prior| {
            if (std.mem.eql(u8, entry.id, prior.id) or entry.character_id == prior.character_id) return error.DuplicatePopulationResource;
        }
    }
    for (scene_data.loaded_requirements, 0..) |entry, index| {
        if (entry.character_id == 0 or entry.resource.len == 0 or entry.graphic.len == 0) return error.InvalidPopulationLoadedRequirement;
        for (scene_data.loaded_requirements[0..index]) |prior| {
            if (entry.character_id == prior.character_id) return error.DuplicatePopulationLoadedRequirement;
        }
    }
    for (scene_data.animations, 0..) |animation, index| {
        if (animation.graphic.len == 0) return error.InvalidPopulationAnimations;
        for (scene_data.animations[0..index]) |prior| if (std.mem.eql(u8, animation.graphic, prior.graphic)) return error.DuplicatePopulationAnimation;
    }

    var slot: u16 = 0;
    var previous_entity: u16 = 0;
    var have_previous = false;
    for (scene_data.records) |*record| {
        if (have_previous and record.entity <= previous_entity) return error.InvalidPopulationRecordOrder;
        previous_entity = record.entity;
        have_previous = true;
        try validateTerms(record.conditions);
        try validateTerms(record.event_conditions);
        if (record.kind == .alias) {
            if (record.slot != null or record.resource != null or record.resource_domain != null or record.graphic != null or record.conditions.len != 0) return error.InvalidPopulationAliasRecord;
            if (slot == 0 or record.alias_slot == null or record.alias_slot.? != slot - 1) return error.InvalidPopulationAliasRecord;
            continue;
        }
        if (record.slot == null or record.slot.? != slot or slot >= scene_data.packet.actors.len) return error.InvalidPopulationRecord;
        if (record.character_id == null or record.character_id.? == 0) return error.InvalidPopulationRecord;
        if (record.resource == null or record.resource_domain == null or record.graphic == null) return error.InvalidPopulationRecord;
        const definition = scene_data.packet.actors[slot];
        if (definition.entity != record.entity or !std.mem.eql(u8, definition.resource, record.resource.?) or
            !std.mem.eql(u8, definition.graphic, record.graphic.?)) return error.PopulationRecordMismatch;
        if (definition.conditions.len != record.conditions.len) return error.PopulationConditionMismatch;
        for (definition.conditions, record.conditions) |condition, term| {
            if (!sameCondition(term, condition)) return error.PopulationConditionMismatch;
        }
        const expected_kind: @TypeOf(record.kind) = if (record.conditions.len == 0) .unconditional else .conditional;
        if (record.kind != expected_kind) return error.InvalidPopulationRecord;
        switch (record.resource_domain.?) {
            .area_character_context => if (!hasAreaResource(scene_data, record.resource.?, record.character_id.?)) return error.UnknownAreaResource,
            .active_party_character => if (!hasLoadedRequirement(scene_data, record)) return error.MissingLoadedRequirement,
        }
        slot += 1;
    }
    if (slot != scene_data.capacity or slot != scene_data.packet.actors.len) return error.InvalidPopulationCapacity;

    for (scene_data.area_resources) |entry| {
        var used = false;
        for (scene_data.records) |record| {
            if (record.kind == .alias) continue;
            if (record.resource_domain == .area_character_context and
                std.mem.eql(u8, record.resource.?, entry.id) and record.character_id.? == entry.character_id) used = true;
        }
        if (!used) return error.UnusedPopulationResource;
    }
    for (scene_data.loaded_requirements) |entry| {
        var used = false;
        for (scene_data.records) |record| {
            if (record.kind == .alias or record.resource_domain != .active_party_character) continue;
            if (record.character_id.? == entry.character_id and std.mem.eql(u8, record.resource.?, entry.resource) and std.mem.eql(u8, record.graphic.?, entry.graphic)) used = true;
        }
        if (!used) return error.UnusedPopulationLoadedRequirement;
    }
}

pub fn validateAsset(asset: *const Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema)) return error.UnsupportedPopulationSchema;
    if (!validHash(asset.content_sha256) or !validHash(asset.source.main_image_sha256)) return error.InvalidPopulationIdentity;
    if (asset.scenes.len == 0 or asset.scenes.len > max_scenes) return error.InvalidPopulationScene;
    for (asset.scenes, 0..) |scene_data, index| {
        for (asset.scenes[0..index]) |prior| if (std.mem.eql(u8, prior.id, scene_data.id)) return error.DuplicatePopulationScene;
        try validateScene(&scene_data);
    }
}

pub fn parseAsset(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validateAsset(&parsed.value);
    return parsed;
}

fn checkLoaded(scene_data: *const SceneData, loaded: Loaded) !void {
    var seen: [256]bool = @splat(false);
    for (loaded.entries) |entry| {
        if (entry.character_id == 0 or entry.resource.len == 0 or entry.graphic.len == 0) return error.InvalidLoadedPartyResource;
        if (seen[entry.character_id]) return error.DuplicateLoadedPartyResource;
        seen[entry.character_id] = true;
    }
    for (scene_data.loaded_requirements) |requirement| {
        var found = false;
        for (loaded.entries) |entry| {
            if (entry.character_id == requirement.character_id and
                std.mem.eql(u8, entry.resource, requirement.resource) and
                std.mem.eql(u8, entry.graphic, requirement.graphic)) found = true;
        }
        if (!found) return error.MissingLoadedPartyResource;
    }
}

fn constructScene(scene_data: *const SceneData, loaded: Loaded, story: event_runtime.StoryState) !field_actors.State {
    try checkLoaded(scene_data, loaded);
    if (!std.mem.eql(u8, story.schema, story_schema)) return error.InvalidConstructionStory;
    return field_actors.State.construct(scene_data.packet, scene_data.animations, story);
}

pub fn open(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    scene_id: []const u8,
    loaded: Loaded,
    construction_story: event_runtime.StoryState,
) !Opened {
    var parsed = try parseAsset(allocator, bytes);
    errdefer parsed.deinit();
    var index: usize = 0;
    while (index < parsed.value.scenes.len) : (index += 1) {
        if (std.mem.eql(u8, parsed.value.scenes[index].id, scene_id)) break;
    } else return error.UnknownPopulationScene;
    const state = try constructScene(&parsed.value.scenes[index], loaded, construction_story);
    return .{ .parsed = parsed, .scene_index = index, .loaded = loaded, .state = state };
}
