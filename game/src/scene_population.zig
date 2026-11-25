const std = @import("std");
const event_runtime = @import("event_runtime");

pub const schema = "suikoden-scene-population/1";
pub const coordinate_schema = "suikoden-scene-population/2";
pub const extended_schema = "suikoden-scene-population/3";
pub const prop_schema = "suikoden-scene-population/4";
pub const max_json_bytes = 2 * 1024 * 1024;
pub const max_entities = 255;
pub const max_predicate_terms = 16;

pub const Source = struct {
    file: []const u8,
    lba: u32,
    size: u32,
    sha256: []const u8,
    room: u8,
};
pub const CoordinateContract = struct {
    source_units: []const u8,
    pixel_units: []const u8,
    source_to_pixel: []const u8,
    axes: []const u8,
    origin: []const u8,
    source_coordinate_max: u16,
    pixel_coordinate_max: u32,
    room_half_width: u16,
    room_half_height: u16,
};
pub const StoryValue = struct {
    id: []const u8,
    storage: enum { scenario },
    byte_index: u8,
};
pub const Program = struct {
    id: []const u8,
    namespace: []const u8,
    content_id: []const u8,
};
pub const Term = struct {
    kind: enum {
        story_mask_set,
        story_mask_clear,
        interaction,
        coordinate_range,
        unsupported,
        hero_x_strict,
        hero_y_strict,
        confirm_pressed,
        pressed_mask,
        room_mask_set,
        room_mask_clear,
        money_at_least,
        party_contains,
        party_excludes,
        recruit_present,
        recruit_absent,
        recruit_ever,
        party_count_equals,
        level_at_least,
        stage_at_least,
        random_chance,
        recruit_count_at_least,
        has_item,
    },
    flag: ?event_runtime.Flag = null,
    semantics: ?[]const u8 = null,
    coordinate: ?struct { axis: enum { x, y }, first: u8, last: u8 } = null,
    character_id: ?u8 = null,
    slot: ?u8 = null,
    level: ?u8 = null,
    stage: ?u8 = null,
    count: ?u16 = null,
    amount: ?u32 = null,
    index: ?u8 = null,
    mask: ?u16 = null,
    divisor: ?u8 = null,
    item_id: ?u16 = null,
    require_key: bool = false, // Legacy wire name: opcode18 requires equipped gear.
};
pub const Predicate = struct {
    pointer_state: enum { present, null },
    terms: []const Term,
};
pub const Position = struct {
    source_x: u16,
    source_y: u16,
    x: i32,
    y: i32,
    placement: enum { placed, unpositioned, off_map_staging, not_applicable },
};
pub const EventReference = struct {
    reference: []const u8,
    status: enum { resolved, source_only },
    program_id: ?[]const u8,
};
pub const Entity = struct {
    id: []const u8,
    source_order: u8,
    record_role: enum { character, event, initialization },
    population_candidate: bool,
    source_character_id: ?u16,
    resource_id: ?[]const u8,
    resource_domain: ?enum { area_character_context, active_party_character },
    position: Position,
    classification: Predicate,
    event_selection: Predicate,
    trigger: enum { ordinary, interaction, area_entry, initialization },
    initialization_order: ?u8,
    event: EventReference,
};
pub const Packet = struct {
    schema: []const u8,
    id: []const u8,
    content_sha256: []const u8,
    source: Source,
    coordinate_contract: CoordinateContract,
    duplicate_policy: []const u8,
    story_values: []const StoryValue,
    programs: []const Program,
    entities: []const Entity,

    pub fn storyValue(self: Packet, id: []const u8) ?StoryValue {
        for (self.story_values) |value| if (std.mem.eql(u8, value.id, id)) return value;
        return null;
    }
    pub fn program(self: Packet, id: []const u8) ?Program {
        for (self.programs) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
};

pub const Facts = struct {
    story: *const event_runtime.StoryState,
    active_party_count: u8,
    party: []const u8 = &.{},
    levels: ?*const [hq_level_slots]u8 = null,
    room_flags: ?*const [20]u8 = null,
    money: u32 = 0,
    direction_mask: u32 = 0,
    confirm_pressed: bool = false,
    item_ids: ?[]const u16 = null,
    equipped_item_ids: ?[]const u16 = null,
    rng: u32 = 0,
};
pub const Selection = struct { entities: []const Entity };

pub const Cell = struct {
    x: u8,
    y: u8,

    pub fn fromPixels(x: i32, y: i32) ?Cell {
        if (@mod(x, 8) != 0 or @mod(y, 8) != 0) return null;
        return .{ .x = std.math.cast(u8, @divExact(x, 8)) orelse return null, .y = std.math.cast(u8, @divExact(y, 8)) orelse return null };
    }
};

fn containsU8(haystack: []const u8, needle: u8) bool {
    for (haystack) |entry| if (entry == needle) return true;
    return false;
}

fn containsU16(haystack: []const u16, needle: u16) bool {
    for (haystack) |entry| if (entry == needle) return true;
    return false;
}

pub fn eventTermMatchesWithFacts(term: Term, facts: Facts, interaction: bool, cell: ?Cell) ?bool {
    return switch (term.kind) {
        .story_mask_set, .story_mask_clear => facts.story.matches(&.{.{
            .kind = if (term.kind == .story_mask_set) .story_mask_set else .story_mask_clear,
            .flag = term.flag.?,
        }}),
        .interaction => interaction,
        .coordinate_range => blk: {
            const position = cell orelse return null;
            const range = term.coordinate.?;
            const coordinate = if (range.axis == .x) position.x else position.y;
            break :blk range.first <= coordinate and coordinate <= range.last;
        },
        .hero_x_strict, .hero_y_strict => blk: {
            const position = cell orelse return null;
            const range = term.coordinate.?;
            const coordinate = if (range.axis == .x) position.x else position.y;
            break :blk range.first < coordinate and coordinate < range.last;
        },
        .confirm_pressed => facts.confirm_pressed,
        .pressed_mask => (facts.direction_mask & @as(u32, term.mask.?)) != 0,
        .room_mask_set => blk: {
            const local = facts.room_flags orelse break :blk false;
            const idx = term.index.?;
            break :blk idx < 20 and (local[idx] & @as(u8, @truncate(term.mask.?))) != 0;
        },
        .room_mask_clear => blk: {
            const local = facts.room_flags orelse break :blk true;
            const idx = term.index.?;
            break :blk idx < 20 and (local[idx] & @as(u8, @truncate(term.mask.?))) == 0;
        },
        .money_at_least => facts.money >= term.amount.?,
        .party_contains => containsU8(facts.party, term.character_id.?),
        .party_excludes => !containsU8(facts.party, term.character_id.?),
        .recruit_present => blk: {
            const slot = term.slot.?;
            if (slot >= hq_flag_slots) break :blk false;
            const b = facts.story.recruit_flags[slot];
            break :blk (b & 1) != 0 and (b & 2) == 0;
        },
        .recruit_absent => blk: {
            const slot = term.slot.?;
            if (slot >= hq_flag_slots) break :blk false;
            break :blk (facts.story.recruit_flags[slot] & 3) == 0;
        },
        .recruit_ever => blk: {
            const slot = term.slot.?;
            if (slot >= hq_flag_slots) break :blk false;
            break :blk (facts.story.recruit_flags[slot] & 3) != 0;
        },
        .party_count_equals => @as(u16, facts.active_party_count) == term.count.?,
        .level_at_least => blk: {
            const table = facts.levels orelse break :blk false;
            const current = table[term.character_id.?];
            break :blk current != 0 and current >= term.level.?;
        },
        .stage_at_least => facts.story.castle_tier >= term.stage.?,
        .random_chance => blk: {
            const q = @divTrunc(@as(u32, 0x7fff), @as(u32, term.divisor.?));
            if (q == 0) break :blk true;
            break :blk @divTrunc(facts.rng & 0x7fff, q) == 0;
        },
        .recruit_count_at_least => @as(u16, facts.story.recruitCount()) >= term.count.?,
        .has_item => item: {
            const ids = (if (term.require_key) facts.equipped_item_ids else facts.item_ids) orelse break :item null;
            break :item containsU16(ids, term.item_id.?);
        },
        .unsupported => null,
    };
}

pub fn eventTermMatches(term: Term, story: *const event_runtime.StoryState, interaction: bool, cell: ?Cell) ?bool {
    return eventTermMatchesWithFacts(term, .{ .story = story, .active_party_count = 0 }, interaction, cell);
}

fn validId(id: []const u8) !void {
    if (id.len == 0 or id.len > 96) return error.InvalidPopulationId;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidPopulationId;
}

fn validHash(hash: []const u8) !void {
    if (hash.len != 64) return error.InvalidPopulationIdentity;
    for (hash) |byte| if (!std.ascii.isHex(byte)) return error.InvalidPopulationIdentity;
}

fn parseScenarioId(id: []const u8) ?u16 {
    if (id.len != 13 or !std.mem.startsWith(u8, id, "scenario_")) return null;
    return std.fmt.parseInt(u16, id[9..], 10) catch null;
}

fn validatePredicate(packet: Packet, predicate: Predicate, event: bool) !void {
    if (predicate.pointer_state == .null and predicate.terms.len != 0) return error.InvalidPopulationPredicate;
    if (predicate.terms.len > max_predicate_terms) return error.TooManyPopulationPredicates;
    const is_extended = std.mem.eql(u8, packet.schema, extended_schema) or std.mem.eql(u8, packet.schema, prop_schema);
    for (predicate.terms) |term| {
        if (term.kind != .coordinate_range and term.kind != .hero_x_strict and term.kind != .hero_y_strict and term.coordinate != null) return error.InvalidPopulationPredicate;
        switch (term.kind) {
            .story_mask_set, .story_mask_clear => {
                const flag = term.flag orelse return error.InvalidPopulationPredicate;
                if (term.semantics != null or flag.mask == 0 or packet.storyValue(flag.id) == null) return error.UnknownPopulationStoryValue;
            },
            .interaction => if (term.flag != null or term.semantics != null) return error.InvalidPopulationPredicate,
            .coordinate_range => {
                const coordinate = term.coordinate orelse return error.InvalidPopulationPredicate;
                if (!event or (!std.mem.eql(u8, packet.schema, coordinate_schema) and !is_extended) or term.flag != null or term.semantics != null or coordinate.first > coordinate.last) return error.InvalidPopulationPredicate;
            },
            .unsupported => {
                if (term.flag != null) return error.InvalidPopulationPredicate;
                try validId(term.semantics orelse return error.UnsupportedPopulationPredicate);
            },
            else => {
                if (!is_extended or term.flag != null or term.semantics != null) return error.InvalidPopulationPredicate;
                switch (term.kind) {
                    .hero_x_strict, .hero_y_strict => {
                        const coordinate = term.coordinate orelse return error.InvalidPopulationPredicate;
                        if (!event or coordinate.first > coordinate.last) return error.InvalidPopulationPredicate;
                    },
                    .confirm_pressed => if (!event) return error.InvalidPopulationPredicate,
                    .pressed_mask => if (!event or term.mask == null or term.mask.? == 0) return error.InvalidPopulationPredicate,
                    .room_mask_set, .room_mask_clear => if (term.index == null or term.index.? >= 20 or term.mask == null or term.mask.? == 0) return error.InvalidPopulationPredicate,
                    .money_at_least => if (!event or term.amount == null) return error.InvalidPopulationPredicate,
                    .party_contains, .party_excludes => if (term.character_id == null) return error.InvalidPopulationPredicate,
                    .recruit_present, .recruit_absent, .recruit_ever => if (term.slot == null or term.slot.? >= hq_flag_slots) return error.InvalidPopulationPredicate,
                    .party_count_equals => if (!event or term.count == null or term.count.? > hq_party_slots) return error.InvalidPopulationPredicate,
                    .level_at_least => if (term.character_id == null or term.level == null) return error.InvalidPopulationPredicate,
                    .stage_at_least => if (term.stage == null or term.stage.? >= 5) return error.InvalidPopulationPredicate,
                    .random_chance => if (term.divisor == null or term.divisor.? == 0) return error.InvalidPopulationPredicate,
                    .recruit_count_at_least => if (term.count == null or term.count.? > hq_flag_slots) return error.InvalidPopulationPredicate,
                    .has_item => if (!event or term.item_id == null) return error.InvalidPopulationPredicate,
                    else => unreachable,
                }
            },
        }
    }
}

fn expectedPlacement(position: Position, contract: CoordinateContract, character: bool) @TypeOf(position.placement) {
    if (!character) return .not_applicable;
    if (position.source_x > 0 and position.source_x < contract.room_half_width and position.source_y > 0 and position.source_y < contract.room_half_height) return .placed;
    if (position.source_x == 0 and position.source_y == 0) return .unpositioned;
    return .off_map_staging;
}

pub fn validate(packet: Packet) !void {
    const is_extended = std.mem.eql(u8, packet.schema, extended_schema) or std.mem.eql(u8, packet.schema, prop_schema);
    if (!is_extended and !std.mem.eql(u8, packet.schema, schema) and !std.mem.eql(u8, packet.schema, coordinate_schema)) return error.UnsupportedPopulationSchema;
    try validId(packet.id);
    try validHash(packet.content_sha256);
    try validHash(packet.source.sha256);
    if (packet.source.file.len == 0 or packet.source.file.len > 128 or !std.unicode.utf8ValidateSlice(packet.source.file) or packet.source.size == 0) return error.InvalidPopulationSource;
    const contract = packet.coordinate_contract;
    if (!std.mem.eql(u8, contract.source_units, "half_cell") or
        !std.mem.eql(u8, contract.pixel_units, "pixel") or
        !std.mem.eql(u8, contract.source_to_pixel, "pixel = source * 8") or
        !std.mem.eql(u8, contract.axes, "x_right_y_down") or
        !std.mem.eql(u8, contract.origin, "room_top_left") or
        contract.source_coordinate_max != 255 or contract.pixel_coordinate_max != 2040 or
        contract.room_half_width == 0 or contract.room_half_height == 0)
        return error.InvalidPopulationCoordinateContract;
    if (!std.mem.eql(u8, packet.duplicate_policy, "preserve_source_records")) return error.UnsupportedPopulationDuplicatePolicy;
    const program_cap: usize = if (is_extended) event_runtime.campaign_max_programs else event_runtime.max_programs;
    if ((!is_extended and packet.entities.len == 0) or packet.entities.len > max_entities or packet.story_values.len > 240 or packet.programs.len > program_cap) return error.InvalidPopulationContent;

    for (packet.story_values, 0..) |value, index| {
        try validId(value.id);
        const byte_index = parseScenarioId(value.id) orelse return error.InvalidPopulationStoryValue;
        if (byte_index >= 240 or byte_index != value.byte_index) return error.InvalidPopulationStoryValue;
        for (packet.story_values[0..index]) |other| {
            if (std.mem.eql(u8, value.id, other.id) or value.byte_index == other.byte_index) return error.DuplicatePopulationStoryValue;
        }
    }
    for (packet.programs, 0..) |program, index| {
        try validId(program.id);
        try validId(program.content_id);
        const valid_namespace = std.mem.eql(u8, program.namespace, event_runtime.schema) or
            (is_extended and event_runtime.schema_versions.isCampaignNamespace(program.namespace));
        if (!valid_namespace) return error.UnsupportedPopulationProgramNamespace;
        for (packet.programs[0..index]) |other| if (std.mem.eql(u8, program.id, other.id)) return error.DuplicatePopulationProgram;
    }

    var next_initialization: u8 = 0;
    for (packet.entities, 0..) |entity, index| {
        try validId(entity.id);
        try validId(entity.event.reference);
        if (entity.source_order != index) return error.InvalidPopulationSourceOrder;
        for (packet.entities[0..index]) |other| {
            if (std.mem.eql(u8, entity.id, other.id)) return error.DuplicatePopulationEntity;
            if (std.mem.eql(u8, entity.event.reference, other.event.reference)) return error.DuplicatePopulationEventReference;
        }
        const character = entity.record_role == .character;
        const prop = std.mem.eql(u8, packet.schema, prop_schema) and entity.record_role == .event and
            entity.trigger == .interaction and entity.position.placement == .placed;
        if (character) {
            if (entity.source_character_id == null or entity.source_character_id.? == 0 or entity.resource_id == null or entity.resource_domain == null or entity.initialization_order != null or entity.trigger == .initialization) return error.InvalidPopulationEntityRole;
            try validId(entity.resource_id.?);
        } else {
            if (entity.source_character_id != null or entity.resource_id != null or entity.resource_domain != null or entity.population_candidate or (!prop and entity.position.placement != .not_applicable)) return error.InvalidPopulationEntityRole;
        }
        if (entity.record_role == .initialization) {
            if (entity.initialization_order == null or entity.initialization_order.? != next_initialization or entity.trigger != .initialization) return error.InvalidPopulationInitialization;
            next_initialization += 1;
        } else if (entity.initialization_order != null) return error.InvalidPopulationInitialization;
        if (entity.population_candidate and !character) return error.InvalidPopulationCandidate;

        const position = entity.position;
        if (position.source_x > contract.source_coordinate_max or position.source_y > contract.source_coordinate_max) return error.InvalidPopulationSourceCoordinate;
        if (position.x < 0 or position.y < 0 or position.x > contract.pixel_coordinate_max or position.y > contract.pixel_coordinate_max) return error.InvalidPopulationPixelCoordinate;
        if (position.x != @as(i32, position.source_x) * 8 or position.y != @as(i32, position.source_y) * 8) return error.PopulationCoordinateMismatch;
        if (position.placement != expectedPlacement(position, contract, character or prop)) return error.InvalidPopulationPlacement;
        try validatePredicate(packet, entity.classification, false);
        try validatePredicate(packet, entity.event_selection, true);

        switch (entity.event.status) {
            .resolved => {
                const program_id = entity.event.program_id orelse return error.UnknownPopulationProgram;
                if (packet.program(program_id) == null) return error.UnknownPopulationProgram;
            },
            .source_only => if (entity.event.program_id != null) return error.InvalidPopulationEventReference,
        }
    }
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    if (bytes.len > max_json_bytes) return error.PopulationContentTooLarge;
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

const Eligibility = enum { eligible, ineligible, unsupported };

pub fn eligibility(entity: Entity, facts: Facts) Eligibility {
    if (!entity.population_candidate) return .ineligible;
    return classificationEligibility(entity, facts);
}

pub fn isPlacedInteraction(entity: Entity) bool {
    return entity.trigger == .interaction and entity.position.placement == .placed and
        (entity.population_candidate or entity.record_role == .event);
}

pub fn interactionEligibility(entity: Entity, facts: Facts) Eligibility {
    if (!isPlacedInteraction(entity)) return .ineligible;
    return classificationEligibility(entity, facts);
}

fn classificationEligibility(entity: Entity, facts: Facts) Eligibility {
    if (entity.classification.pointer_state == .null) return .ineligible;
    for (entity.classification.terms) |term| {
        switch (term.kind) {
            .interaction, .coordinate_range, .unsupported => return .unsupported,
            .hero_x_strict, .hero_y_strict, .confirm_pressed, .pressed_mask, .money_at_least, .party_count_equals, .has_item => return .ineligible,
            else => {
                const matched = eventTermMatchesWithFacts(term, facts, false, null) orelse return .unsupported;
                if (!matched) return .ineligible;
            },
        }
    }
    return .eligible;
}

pub fn select(packet: Packet, facts: Facts, output: []Entity) !Selection {
    try validate(packet);
    var count: usize = 0;
    for (packet.entities) |entity| {
        switch (eligibility(entity, facts)) {
            .eligible => count += 1,
            .ineligible => {},
            .unsupported => return error.UnsupportedPopulationPredicate,
        }
    }
    if (output.len < count) return error.PopulationOutputTooSmall;
    var output_index: usize = 0;
    for (packet.entities) |entity| {
        if (eligibility(entity, facts) == .eligible) {
            output[output_index] = entity;
            output_index += 1;
        }
    }
    return .{ .entities = output[0..count] };
}

// ---------------------------------------------------------------------------
// Headquarters presence (HQ presence fold)
//
// The HQ stage catalogue carries a richer term shape than an area
// population packet: recruit flags, party membership, persistent levels, the
// castle stage and a recruit count.  The truth table lives *here* so the
// HQ scene builder and the area population owner cannot drift
// apart; the two serialized term shapes stay distinct because the committed
// assets differ, and each is validated by its own schema rule.
// ---------------------------------------------------------------------------

pub const hq_flag_slots = 108;
pub const hq_party_slots = 6;
pub const hq_level_slots = 256;

pub const HqTerm = struct {
    kind: enum {
        story_mask_set,
        story_mask_clear,
        party_contains,
        party_excludes,
        recruit_present,
        recruit_absent,
        recruit_ever,
        level_at_least,
        stage_at_least,
        recruit_count_at_least,
        party_count_equals,
        interaction,
        direction,
        trigger_x,
        trigger_y,
        unproved,
    },
    flag: ?event_runtime.Flag = null,
    character_id: ?u8 = null,
    slot: ?u8 = null,
    level: ?u8 = null,
    stage: ?u8 = null,
    count: ?u16 = null,
    lower: ?u16 = null,
    upper: ?u16 = null,
    mask: ?u16 = null,
    index: ?u8 = null,
    semantics: ?[]const u8 = null,
};

pub const HqRoster = struct {
    /// The 108 canonical recruit bytes (`gs+0x1AF4`): bit0 recruited, bit1 removed.
    recruit: *const [hq_flag_slots]u8,
    /// Active party source character ids, in party order.
    party: []const u8,
    /// Persistent level by source character id; 0 means unknown.
    levels: *const [hq_level_slots]u8,
};

pub const HqFacts = struct {
    stage: u8,
    story: *const event_runtime.StoryState,
    roster: HqRoster,
};

fn hqParseScenarioId(id: []const u8) ?u8 {
    if (id.len != 13 or !std.mem.startsWith(u8, id, "scenario_")) return null;
    return std.fmt.parseInt(u8, id[9..], 10) catch null;
}

/// One term's schema rule.  A term whose fact field is missing is invalid, not
/// defaulted: the same rule the headquarters catalogue validates against.
pub fn validateHqTerm(term: HqTerm) !void {
    switch (term.kind) {
        .story_mask_set, .story_mask_clear => {
            const flag = term.flag orelse return error.InvalidTerm;
            if (flag.mask == 0 or hqParseScenarioId(flag.id) == null) return error.InvalidTerm;
        },
        .party_contains, .party_excludes => if (term.character_id == null) return error.InvalidTerm,
        .recruit_present, .recruit_absent, .recruit_ever => {
            const slot = term.slot orelse return error.InvalidTerm;
            if (slot >= hq_flag_slots) return error.InvalidTerm;
        },
        .level_at_least => {
            if (term.character_id == null or term.level == null or term.level.? == 0) return error.InvalidTerm;
        },
        .stage_at_least => {
            const value = term.stage orelse return error.InvalidTerm;
            if (value >= 5) return error.InvalidTerm;
        },
        .recruit_count_at_least => if ((term.count orelse hq_flag_slots + 1) > hq_flag_slots) return error.InvalidTerm,
        .party_count_equals => if ((term.count orelse hq_party_slots + 1) > hq_party_slots) return error.InvalidTerm,
        .interaction, .direction, .trigger_x, .trigger_y => {},
        .unproved => if (term.semantics == null) return error.InvalidTerm,
    }
}

/// True when every term is a proved source condition (no `unproved`).
pub fn hqTermsProved(terms: []const HqTerm) bool {
    for (terms) |term| if (term.kind == .unproved) return false;
    return true;
}

fn hqContainsParty(party: []const u8, id: u8) bool {
    for (party) |member| if (member == id) return true;
    return false;
}

fn hqPresentRecruits(recruit: *const [hq_flag_slots]u8) u16 {
    var count: u16 = 0;
    for (recruit) |byte| {
        if (byte & 1 != 0 and byte & 2 == 0) count += 1;
    }
    return count;
}

/// Evaluate a conjunction of proved headquarters terms.  A term whose fact is
/// unavailable (unknown level) or whose semantic is unproved returns false: no
/// default.  `interaction`, `direction` and the trigger terms are not presence
/// gates; the compiler keeps them out of actor classification, so seeing one
/// here means the asset is wrong.
pub fn hqTermsSatisfied(terms: []const HqTerm, facts: HqFacts) bool {
    for (terms) |term| {
        switch (term.kind) {
            .story_mask_set, .story_mask_clear => {
                const flag = term.flag orelse return false;
                const conditions = [1]event_runtime.Condition{.{
                    .kind = if (term.kind == .story_mask_set) .story_mask_set else .story_mask_clear,
                    .flag = flag,
                }};
                if (!facts.story.matches(&conditions)) return false;
            },
            .party_contains => {
                const id = term.character_id orelse return false;
                if (!hqContainsParty(facts.roster.party, id)) return false;
            },
            .party_excludes => {
                const id = term.character_id orelse return false;
                if (hqContainsParty(facts.roster.party, id)) return false;
            },
            .recruit_present => {
                const slot = term.slot orelse return false;
                const byte = facts.roster.recruit[slot];
                if (byte & 1 == 0 or byte & 2 != 0) return false;
            },
            .recruit_absent => {
                const slot = term.slot orelse return false;
                if (facts.roster.recruit[slot] & 3 != 0) return false;
            },
            .recruit_ever => {
                const slot = term.slot orelse return false;
                if (facts.roster.recruit[slot] & 3 == 0) return false;
            },
            .level_at_least => {
                const id = term.character_id orelse return false;
                const level = term.level orelse return false;
                const current = facts.roster.levels[id];
                if (current == 0) return false;
                if (current < level) return false;
            },
            .stage_at_least => {
                const threshold = (term.stage orelse return false);
                if (facts.stage < threshold) return false;
            },
            .recruit_count_at_least => {
                const threshold = term.count orelse return false;
                if (hqPresentRecruits(facts.roster.recruit) < threshold) return false;
            },
            .party_count_equals => {
                const expected = term.count orelse return false;
                if (facts.roster.party.len != expected) return false;
            },
            .interaction, .direction, .trigger_x, .trigger_y => return false,
            .unproved => return false,
        }
    }
    return true;
}
