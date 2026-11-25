//! Destination catalogue: Viki's 37 source destinations, the Blinking
//! Mirror's five castle tiers and the Escape Talisman's retained-point family.
//!
//! The packet is produced by the extraction pipeline from static source
//! facts (the stage-A/B/C overlays agree byte for byte on the destination table
//! and the name pointers).  This file only validates the qualified data and
//! computes the content digest; it neither opens a disc nor allocates.
//!
//! Units are explicit: `source_spawn` is a source half-cell byte pair and
//! `spawn` is the same position in field pixels (half-cell * 8).  `world_camera`
//! is a world cell pair.  `region`/`point` are the source indices that MAIN's
//! point resolver consumes, not coordinates.

const std = @import("std");

pub const schema_viki = "suikoden-viki-destinations/2";
pub const schema_mirror = "suikoden-mirror-destinations/2";
pub const viki_content_id = "viki_us_11";
pub const mirror_content_id = "main_us_11_mirror_items";
pub const max_destinations = 37;
pub const max_tiers = 5;
pub const rows_per_page = 9;
pub const viki_request_entry = 0x800136B4;
pub const viki_callback_index = 3;
pub const viki_callback_selector = 0xFF;
pub const viki_admission_room = 2;
pub const blinking_mirror_item = 81;
pub const blinking_mirror_handler = 13;
pub const escape_item = 73;
pub const escape_handler = 12;
pub const escape_bit_mask = 2;

pub const Point = struct { x: u16, y: u16 };

pub const Source = struct {
    file: []const u8,
    lba: u32,
    size: u32,
    sha256: []const u8,
    body_sha256: ?[]const u8 = null,
    body_offset: ?u32 = null,
};

pub const Witness = struct {
    file: []const u8,
    sha256: []const u8,
    table_offset: u32,
    table_address: []const u8,
    labels_offset: u32,
    labels_address: []const u8,
    record_bytes: u32,
    table_matches_primary: bool,
    names_match_primary: bool,
};

pub const Table = struct {
    source: []const u8,
    offset: u32,
    address: []const u8,
    entry_bytes: u8,
    count: u8,
    fields: [4][]const u8,
    scan_bound: u8,
    scan_constant: []const u8,
    first_record: [4]u8,
    last_record: [4]u8,
};

pub const Unlock = struct {
    storage: []const u8,
    byte_index: u8,
    mask: u8,
    flag_id: []const u8,
};

pub const Spawn = struct {
    domain: []const u8,
    x: u16,
    y: u16,
};

pub const Arrival = struct {
    kind: []const u8,
    area: []const u8,
    area_lba: u32,
    area_size: u32,
    area_sha256: []const u8,
    room: u8,
    source_spawn: Spawn,
    spawn: Spawn,
    world_camera: ?Spawn = null,
};

pub const Destination = struct {
    id: []const u8,
    source_order: u8,
    name: []const u8,
    unlock: Unlock,
    region: u8,
    region_id: []const u8,
    point: u8,
    point_id: []const u8,
    arrival: Arrival,
    provenance: std.json.Value = .null,
};

pub const Word = struct {
    address: []const u8,
    word: []const u8,
    meaning: []const u8,
};

pub const Op = struct {
    opcode: []const u8,
    offset: []const u8,
};

pub const ModeSwitch = struct {
    opcode: []const u8,
    offset: []const u8,
    selector: u8,
};

pub const Transition = struct {
    opcode: []const u8,
    offset: []const u8,
    selector: u8,
    index: u8,
    operands: []const u8,
};

pub const CallbackTable = struct {
    base: []const u8,
    offset: u32,
    index: u8,
    entry: []const u8,
    entries: []const []const u8,
};

pub const Actor = struct {
    entity: u8,
    character_id: u16,
    role: []const u8,
    x_half: u16,
    y_half: u16,
    talk_stream: []const u8,
};

pub const Admission = struct {
    kind: []const u8,
    source: []const u8,
    room: u8,
    actors: []const Actor,
    talk_streams: []const []const u8,
    dialogue_box: Op,
    mode_switch: ModeSwitch,
    transition: Transition,
    callback_table: CallbackTable,
    request_entry: []const u8,
    no_free_menu: bool,
    semantics: []const u8,
    evidence: []const []const u8,
};

pub const Widget = struct {
    object: []const u8,
    global: []const u8,
    list_builder: []const u8,
    input_handler: []const u8,
    eligibility: []const u8,
    apply: []const u8,
    close: []const u8,
    rows_per_page: u8,
    page_bound: []const u8,
    row_bound: []const u8,
    confirm_mask: []const []const u8,
    cancel_mask: []const []const u8,
    confirm_sound: []const u8,
    cancel_sound: []const u8,
    empty_list: []const u8,
    words: []const Word = &.{},
    admission_words: []const Word = &.{},
};

pub const UnlockSpace = struct {
    storage: []const u8,
    bytes: []const u8,
    mask_values: []const u8,
    coverage: std.json.Value = .null,
    semantics: []const u8,
};

pub const ArrivalContract = struct {
    resolver: []const u8,
    trigger: []const u8,
    area: []const u8,
    world_camera: []const u8,
    units: []const u8,
};

pub const Viki = struct {
    schema: []const u8,
    id: []const u8,
    sources: []const Source,
    witnesses: []const Witness,
    table: Table,
    labels: struct {
        offset: u32,
        address: []const u8,
        pointer_bytes: u8,
        count: u8,
        decoder: []const u8,
        names: []const []const u8,
    },
    unlock: UnlockSpace,
    arrival_contract: ArrivalContract,
    admission: Admission,
    widget: Widget,
    destinations: []const Destination,
    coverage: std.json.Value = .null,
    content_sha256: []const u8,

    pub fn digest(self: Viki) [64]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.destinations) |destination| {
            hashSlice(&hasher, destination.id);
            hashSlice(&hasher, destination.name);
            hashSlice(&hasher, destination.region_id);
            hashSlice(&hasher, destination.point_id);
            // 10 bytes: four source bytes then three little-endian u16 fields,
            // matching the exporter's `struct.pack("<BBBBHHH", ...)`.
            var record: [10]u8 = undefined;
            record[0] = destination.unlock.byte_index;
            record[1] = destination.unlock.mask;
            record[2] = destination.region;
            record[3] = destination.point;
            std.mem.writeInt(u16, record[4..6], destination.arrival.room, .little);
            std.mem.writeInt(u16, record[6..8], destination.arrival.source_spawn.x, .little);
            std.mem.writeInt(u16, record[8..10], destination.arrival.source_spawn.y, .little);
            hasher.update(&record);
            hashSlice(&hasher, destination.arrival.area);
        }
        return std.fmt.bytesToHex(hasher.finalResult(), .lower);
    }

    pub fn validate(self: Viki) !void {
        if (!std.mem.eql(u8, self.schema, schema_viki)) return error.InvalidVikiSchema;
        if (!std.mem.eql(u8, self.id, viki_content_id)) return error.InvalidVikiIdentity;
        if (!std.mem.eql(u8, self.table.source, self.sources[0].file)) return error.InvalidVikiSource;
        if (self.table.entry_bytes != 4 or self.table.count != max_destinations) return error.InvalidVikiTable;
        if (self.table.scan_bound != max_destinations) return error.InvalidVikiScan;
        if (self.witnesses.len != 2) return error.InvalidVikiWitness;
        for (self.witnesses) |witness| {
            if (!witness.table_matches_primary or !witness.names_match_primary) return error.InvalidVikiWitness;
            if (witness.record_bytes != 4 * max_destinations) return error.InvalidVikiWitness;
            if (witness.sha256.len != 64) return error.InvalidVikiWitness;
        }
        if (self.labels.names.len != max_destinations) return error.InvalidVikiNames;
        if (self.destinations.len != max_destinations) return error.InvalidVikiCount;
        if (self.labels.count != max_destinations or self.labels.pointer_bytes != 4) return error.InvalidVikiNames;
        for (self.labels.names, 0..) |name, index| {
            if (name.len == 0) return error.InvalidVikiNames;
            for (self.labels.names[0..index]) |other| {
                if (std.mem.eql(u8, name, other)) return error.InvalidVikiNames;
            }
        }
        if (!std.mem.eql(u8, self.admission.kind, "event_opcode_43")) return error.InvalidVikiAdmission;
        if (self.admission.room != viki_admission_room) return error.InvalidVikiAdmission;
        if (self.admission.transition.selector != viki_callback_selector) return error.InvalidVikiAdmission;
        if (self.admission.transition.index != viki_callback_index) return error.InvalidVikiAdmission;
        if (self.admission.callback_table.index != viki_callback_index) return error.InvalidVikiAdmission;
        if (!std.mem.eql(u8, self.admission.callback_table.entry, self.admission.request_entry)) return error.InvalidVikiAdmission;
        var entry_buffer: [10]u8 = undefined;
        const expected_entry = try std.fmt.bufPrint(&entry_buffer, "0x{x:0>8}", .{viki_request_entry});
        if (!std.mem.eql(u8, self.admission.request_entry, expected_entry)) return error.InvalidVikiAdmission;
        if (self.admission.actors.len != 2) return error.InvalidVikiAdmission;
        if (!self.admission.no_free_menu) return error.InvalidVikiAdmission;
        if (self.widget.rows_per_page != rows_per_page) return error.InvalidVikiWidget;
        if (self.unlock.bytes.len == 0) return error.InvalidVikiUnlock;

        var bits: usize = 0;
        for (self.destinations, 0..) |destination, index| {
            if (destination.source_order != index) return error.InvalidVikiDestination;
            var id_buffer: [24]u8 = undefined;
            const expected_id = try std.fmt.bufPrint(&id_buffer, "viki_destination_{d:0>2}", .{index});
            if (!std.mem.eql(u8, expected_id, destination.id)) return error.InvalidVikiDestination;
            if (destination.name.len == 0) return error.InvalidVikiDestination;
            if (destination.unlock.byte_index >= 240) return error.InvalidVikiDestination;
            if (destination.unlock.mask == 0 or !std.math.isPowerOfTwo(destination.unlock.mask)) return error.InvalidVikiDestination;
            if (destination.region >= 12 or destination.point >= 165) return error.InvalidVikiDestination;
            if (destination.arrival.room >= 64) return error.InvalidVikiDestination;
            if (!std.mem.eql(u8, destination.arrival.kind, "field")) return error.InvalidVikiDestination;
            if (!std.mem.endsWith(u8, destination.arrival.area, ".BIN")) return error.InvalidVikiDestination;
            if (destination.arrival.area_sha256.len != 64) return error.InvalidVikiDestination;
            if (destination.arrival.source_spawn.domain.len == 0 or
                !std.mem.eql(u8, destination.arrival.source_spawn.domain, "half_cell")) return error.InvalidVikiDestination;
            if (destination.arrival.spawn.x != destination.arrival.source_spawn.x * 8 or
                destination.arrival.spawn.y != destination.arrival.source_spawn.y * 8) return error.InvalidVikiDestination;
            if (destination.arrival.source_spawn.x > 255 or destination.arrival.source_spawn.y > 255) return error.InvalidVikiDestination;
            const camera = destination.arrival.world_camera orelse return error.InvalidVikiDestination;
            if (camera.x > 159 or camera.y > 151) return error.InvalidVikiDestination;
            if (!std.mem.eql(u8, destination.unlock.storage, "scenario")) return error.InvalidVikiDestination;
            bits += @as(usize, @popCount(destination.unlock.mask));
        }
        if (bits != max_destinations) return error.InvalidVikiUnlock;
        if (!std.mem.eql(u8, self.content_sha256, &self.digest())) return error.InvalidVikiDigest;
        if (std.mem.eql(u8, self.labels.names[0], "") or
            !std.mem.eql(u8, self.labels.names[0], self.destinations[0].name)) return error.InvalidVikiNames;
    }

    pub fn destinationIndex(self: Viki, id: []const u8) ?u8 {
        for (self.destinations, 0..) |destination, index| {
            if (std.mem.eql(u8, destination.id, id)) return @intCast(index);
        }
        return null;
    }
};

pub const Gate = struct {
    kind: []const u8,
    field: []const u8,
    world_mode_required: u8,
    label: []const u8,
    extra: ?struct {
        predicate: []const u8,
        dispatch: []const u8,
        dispatch_argument: u8,
        dispatch_table: []const u8,
        dispatch_entry: []const u8,
        reads: []const u8,
        mask: u8,
        scenario_byte: u8,
    } = null,
};

pub const DestinationRule = struct {
    kind: []const u8,
    region: u8 = 0,
    room: u8 = 0,
    tier_source: ?[]const u8 = null,
    tiers: []const u8 = &.{},
    resolver: ?[]const u8 = null,
    region_source: ?[]const u8 = null,
    point_source: ?[]const u8 = null,
};

pub const Item = struct {
    id: []const u8,
    item_id: u16,
    label: []const u8,
    category: u8,
    category_label: []const u8,
    record_address: []const u8,
    record_hex: []const u8,
    handler: u8,
    handler_address: []const u8,
    gate: Gate,
    destination: DestinationRule,
    payment: []const u8,
    consumption: []const u8,
    reusable: bool,
    admission: []const u8,
};

pub const Tier = struct {
    tier: u8,
    area_index: u8,
    area: []const u8,
    area_lba: u32,
    area_size: u32,
    area_sha256: []const u8,
    region: u8,
    room: u8,
    source_spawn: Spawn,
    spawn: Spawn,
};

pub const WriteAudit = struct {
    ranges: []const struct { start: []const u8, end: []const u8, label: []const u8 },
    game_state_allowance: []const u8,
    area_state_allowance: []const u8,
    stores: []const struct { address: []const u8, range: []const u8, base: []const u8, width: u8, offset: i32 },
    observation: []const u8,
};

pub const Mirror = struct {
    schema: []const u8,
    id: []const u8,
    sources: []const Source,
    item_handler_table: struct { address: []const u8, index_12: []const u8, index_13: []const u8 },
    items: []const Item,
    tier_table: struct { address: []const u8, bytes: []const u8, count: u8, source: []const u8, semantics: []const u8 },
    tiers: []const Tier,
    resolver: struct { address: []const u8, contract: []const u8 },
    world_mode: std.json.Value = .null,
    write_audit: WriteAudit,
    words: []const Word = &.{},
    coverage: std.json.Value = .null,
    content_sha256: []const u8,

    pub fn digest(self: Mirror) [64]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.items) |item| {
            hashSlice(&hasher, item.id);
            const head = [4]u8{ @intCast(item.item_id), item.category, item.handler, item.gate.world_mode_required };
            hasher.update(&head);
            hashSlice(&hasher, item.label);
        }
        for (self.tiers) |tier| {
            hashSlice(&hasher, tier.area);
            const head = [4]u8{ tier.tier, tier.area_index, tier.region, tier.room };
            hasher.update(&head);
            var spawn: [4]u8 = undefined;
            std.mem.writeInt(u16, spawn[0..2], tier.source_spawn.x, .little);
            std.mem.writeInt(u16, spawn[2..4], tier.source_spawn.y, .little);
            hasher.update(&spawn);
        }
        const extra = [1]u8{escape_bit_mask};
        hasher.update(&extra);
        return std.fmt.bytesToHex(hasher.finalResult(), .lower);
    }

    pub fn validate(self: Mirror) !void {
        if (!std.mem.eql(u8, self.schema, schema_mirror)) return error.InvalidMirrorSchema;
        if (!std.mem.eql(u8, self.id, mirror_content_id)) return error.InvalidMirrorIdentity;
        if (self.sources.len != 1 or !std.mem.eql(u8, self.sources[0].file, "MAIN.EXE")) return error.InvalidMirrorSource;
        if (self.items.len != 2) return error.InvalidMirrorItems;
        if (self.tiers.len != max_tiers) return error.InvalidMirrorTiers;
        if (self.tier_table.bytes.len != max_tiers) return error.InvalidMirrorTiers;
        if (!std.mem.eql(u8, self.item_handler_table.index_13, "0x800d1384")) return error.InvalidMirrorItems;
        if (!std.mem.eql(u8, self.item_handler_table.index_12, "0x800d12cc")) return error.InvalidMirrorItems;
        var blinking: ?Item = null;
        var escape: ?Item = null;
        for (self.items) |item| {
            if (item.item_id == blinking_mirror_item) {
                blinking = item;
            } else if (item.item_id == escape_item) {
                escape = item;
            } else return error.InvalidMirrorItems;
            if (item.category != 8 or item.record_hex.len != 64) return error.InvalidMirrorItems;
            if (!std.mem.eql(u8, item.payment, "none") or !std.mem.eql(u8, item.consumption, "none")) return error.InvalidMirrorItems;
            if (!item.reusable) return error.InvalidMirrorItems;
            if (!std.mem.eql(u8, item.gate.kind, "world_mode")) return error.InvalidMirrorItems;
            if (!std.mem.eql(u8, item.gate.field, "game_state+0x2E")) return error.InvalidMirrorItems;
        }
        const blinking_item = blinking orelse return error.InvalidMirrorItems;
        const escape_item_value = escape orelse return error.InvalidMirrorItems;
        if (blinking_item.handler != blinking_mirror_handler) return error.InvalidMirrorItems;
        if (escape_item_value.handler != escape_handler) return error.InvalidMirrorItems;
        if (blinking_item.gate.world_mode_required != 1 or escape_item_value.gate.world_mode_required != 0) return error.InvalidMirrorItems;
        const extra = escape_item_value.gate.extra orelse return error.InvalidMirrorItems;
        if (extra.mask != escape_bit_mask) return error.InvalidMirrorItems;
        if (!std.mem.endsWith(u8, extra.reads, "+0x1B6")) return error.InvalidMirrorItems;
        if (extra.scenario_byte >= 240) return error.InvalidMirrorItems;
        if (!std.mem.eql(u8, blinking_item.destination.kind, "castle_tier")) return error.InvalidMirrorItems;
        if (!std.mem.eql(u8, escape_item_value.destination.kind, "retained_point")) return error.InvalidMirrorItems;
        if (blinking_item.destination.region != 1 or blinking_item.destination.room != 2) return error.InvalidMirrorItems;
        for (self.tiers, 0..) |tier, index| {
            if (tier.tier != index) return error.InvalidMirrorTiers;
            if (tier.area_index != self.tier_table.bytes[index]) return error.InvalidMirrorTiers;
            if (tier.region != 1 or tier.room != 2) return error.InvalidMirrorTiers;
            if (tier.source_spawn.x != 14 or tier.source_spawn.y != 15) return error.InvalidMirrorTiers;
            if (tier.spawn.x != 112 or tier.spawn.y != 120) return error.InvalidMirrorTiers;
            if (!std.mem.endsWith(u8, tier.area, ".BIN") or tier.area_sha256.len != 64) return error.InvalidMirrorTiers;
        }
        if (!std.mem.eql(u8, self.tiers[3].area, self.tiers[4].area)) return error.InvalidMirrorTiers;
        if (std.mem.eql(u8, self.tiers[0].area, self.tiers[1].area)) return error.InvalidMirrorTiers;
        if (!std.mem.eql(u8, self.content_sha256, &self.digest())) return error.InvalidMirrorDigest;
    }

    pub fn itemById(self: Mirror, item_id: u16) ?Item {
        for (self.items) |entry| {
            if (entry.item_id == item_id) return entry;
        }
        return null;
    }
};

fn hashSlice(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hasher.update(value);
    hasher.update(&[_]u8{0});
}

pub const Loaded = struct {
    viki: std.json.Parsed(Viki),
    mirror: std.json.Parsed(Mirror),

    pub fn deinit(self: *Loaded) void {
        self.viki.deinit();
        self.mirror.deinit();
    }
};

/// Parse and validate both packets.  The returned `Loaded` must outlive any
/// `Session` opened from it: the plan slices borrow these rows.
pub fn load(allocator: std.mem.Allocator, viki_bytes: []const u8, mirror_bytes: []const u8) !Loaded {
    if (viki_bytes.len > 256 * 1024 or mirror_bytes.len > 128 * 1024) return error.PacketTooLarge;
    const viki = try std.json.parseFromSlice(Viki, allocator, viki_bytes, .{ .allocate = .alloc_always });
    errdefer viki.deinit();
    const mirror = try std.json.parseFromSlice(Mirror, allocator, mirror_bytes, .{ .allocate = .alloc_always });
    errdefer mirror.deinit();
    try viki.value.validate();
    try mirror.value.validate();
    return .{ .viki = viki, .mirror = mirror };
}
