const std = @import("std");
const events = @import("event_runtime");
const items = @import("item_ledger");
const party = @import("party_session");

pub const schema = "suikoden-middle-items/1";

pub const Source = struct { file: []const u8, lba: u32, size: u32, sha256: []const u8 };
pub const SourceRef = struct { path: []const u8, sha256: []const u8 };
pub const Entry = struct {
    id: []const u8,
    source_file: []const u8,
    room: u8,
    entity_ids: []const u8,
    stream: u32,
    offset: u32,
    selector: u8,
    source_item_id: u16,
    item_id: []const u8,
    character_id: ?u8 = null,
    member_id: ?[]const u8 = null,
    operation: []const u8,
    construction_state: []const u8,
    construction_predicates: []const []const u8,
    admission_state: []const u8,
    conditions: []const events.Condition,
    requires_interaction: bool,
    unsupported_offsets: []const u32,
    runtime_state: []const u8,
};
pub const RunningWaterRoot = struct {
    acquire_entry: []const u8,
    consume_entry: []const u8,
    consume_story_byte: u8,
    consume_story_mask: u8,
};
pub const Coverage = struct {
    source_files: u16,
    operations: u16,
    acquire: u16,
    remove: u16,
    warehouse_deposits: u16,
    unsupported_selectors: u16,
    adapter_ready: u16,
    blocked_admission: u16,
    production_bindings: u16,
    canonical_route_witnesses: u16,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    item_source: SourceRef,
    roster_source: SourceRef,
    sources: []const Source,
    entries: []const Entry,
    running_water_root: RunningWaterRoot,
    coverage: Coverage,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8, packet: items.catalogue.Packet) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value, packet);
    return parsed;
}

pub fn entryById(asset: Asset, id: []const u8) ?Entry {
    for (asset.entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

pub fn entryAt(asset: Asset, source_file: []const u8, offset: u32) ?Entry {
    for (asset.entries) |entry| {
        if (entry.offset == offset and std.mem.eql(u8, entry.source_file, source_file)) return entry;
    }
    return null;
}

fn knownSource(asset: Asset, path: []const u8) bool {
    for (asset.sources) |source| {
        if (std.mem.eql(u8, source.file, path)) return true;
    }
    return false;
}

fn validCondition(condition: events.Condition) bool {
    if (condition.flag.mask == 0 or condition.flag.id.len != 13 or
        !std.mem.startsWith(u8, condition.flag.id, "scenario_")) return false;
    const index = std.fmt.parseInt(u8, condition.flag.id[9..], 10) catch return false;
    return index < 240;
}

fn validateEntry(entry: Entry, packet: items.catalogue.Packet) !void {
    if (entry.entity_ids.len == 0 or entry.construction_predicates.len != entry.entity_ids.len or
        !std.mem.eql(u8, entry.construction_state, "caller_owned_snapshot")) return error.InvalidItemConstruction;
    for (entry.conditions) |condition| {
        if (!validCondition(condition)) return error.InvalidItemAdmission;
    }
    switch (entry.selector) {
        0, 1 => {
            if (entry.character_id != null or entry.member_id != null) return error.InvalidItemOperation;
            const item = items.catalogue.findBySourceId(packet, entry.source_item_id) orelse return error.UnknownItemIdentity;
            if (!std.mem.eql(u8, item.id, entry.item_id)) return error.MismatchedItemIdentity;
            if (item.ownership != .shared_key) return error.InvalidSharedItem;
            const expected = if (entry.selector == 0) "acquire" else "remove";
            if (!std.mem.eql(u8, entry.operation, expected)) return error.InvalidItemOperation;
        },
        2 => {
            if (entry.source_item_id != 0 or entry.item_id.len != 0 or
                !std.mem.eql(u8, entry.operation, "warehouse_deposit_all_eligible")) return error.InvalidItemOperation;
            const character_id = entry.character_id orelse return error.InvalidWarehouseCharacter;
            const member_id = entry.member_id orelse return error.InvalidWarehouseCharacter;
            const expected = switch (character_id) {
                2 => "gremio",
                6 => "pahn",
                else => return error.InvalidWarehouseCharacter,
            };
            if (!std.mem.eql(u8, member_id, expected)) return error.InvalidWarehouseCharacter;
        },
        else => return error.InvalidItemOperation,
    }
    if (std.mem.eql(u8, entry.admission_state, "unsupported")) {
        if (!std.mem.eql(u8, entry.runtime_state, "blocked_unsupported_admission") or
            entry.unsupported_offsets.len == 0) return error.InvalidItemAdmission;
    } else {
        if (!std.mem.eql(u8, entry.runtime_state, "adapter_ready") or
            entry.unsupported_offsets.len != 0 or
            (!std.mem.eql(u8, entry.admission_state, "decoded") and
                !std.mem.eql(u8, entry.admission_state, "null"))) return error.InvalidItemAdmission;
    }
}

pub fn validate(asset: Asset, packet: items.catalogue.Packet) !void {
    try items.catalogue.validatePacket(packet);
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64)
        return error.InvalidProgressionSchema;
    if (!std.mem.eql(u8, asset.item_source.sha256, items.catalogue.expected_asset_sha256) or
        !std.mem.eql(u8, asset.roster_source.sha256, "ce615fe3fa7cb3bb79c63cb4c6008e856ca1d306eff4e09a6980026bb74baf29"))
        return error.StaleItemSource;
    var acquire: u16 = 0;
    var remove: u16 = 0;
    var deposits: u16 = 0;
    var unsupported: u16 = 0;
    var ready: u16 = 0;
    var blocked: u16 = 0;
    for (asset.entries, 0..) |entry, index| {
        if (!knownSource(asset, entry.source_file)) return error.UnknownItemSource;
        try validateEntry(entry, packet);
        for (asset.entries[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, entry.id) or
                (earlier.offset == entry.offset and earlier.room == entry.room and
                    std.mem.eql(u8, earlier.source_file, entry.source_file))) return error.DuplicateItemOperation;
        }
        switch (entry.selector) {
            0 => acquire += 1,
            1 => remove += 1,
            2 => deposits += 1,
            else => unsupported += 1,
        }
        if (std.mem.eql(u8, entry.runtime_state, "adapter_ready")) ready += 1;
        if (std.mem.eql(u8, entry.runtime_state, "blocked_unsupported_admission")) blocked += 1;
    }
    const coverage = asset.coverage;
    if (asset.sources.len != 19 or asset.entries.len != 30 or
        coverage.source_files != asset.sources.len or coverage.operations != asset.entries.len or
        coverage.acquire != acquire or coverage.remove != remove or
        coverage.warehouse_deposits != deposits or coverage.unsupported_selectors != unsupported or
        coverage.adapter_ready != ready or coverage.blocked_admission != blocked or
        acquire != 17 or remove != 11 or deposits != 2 or unsupported != 0 or ready != 27 or blocked != 3 or
        coverage.production_bindings != 0 or coverage.canonical_route_witnesses != 0)
        return error.InvalidProgressionCoverage;
    const witness = asset.running_water_root;
    const acquire_entry = entryById(asset, witness.acquire_entry) orelse return error.InvalidRootWitness;
    const consume_entry = entryById(asset, witness.consume_entry) orelse return error.InvalidRootWitness;
    if (acquire_entry.selector != 0 or consume_entry.selector != 1 or
        !std.mem.eql(u8, acquire_entry.item_id, "running_water_root") or
        !std.mem.eql(u8, consume_entry.item_id, acquire_entry.item_id) or
        witness.consume_story_byte != 16 or witness.consume_story_mask != 0x20)
        return error.InvalidRootWitness;
}

pub const Facts = struct {
    story: *const events.StoryState,
    entity_retained: bool,
    interaction: bool,
};

fn admit(entry: Entry, facts: Facts) !void {
    if (!facts.entity_retained) return error.EntityNotRetained;
    if (std.mem.eql(u8, entry.admission_state, "unsupported")) return error.UnsupportedAdmission;
    if (entry.requires_interaction and !facts.interaction) return error.InteractionRequired;
    if (!facts.story.matches(entry.conditions)) return error.AdmissionClosed;
}

pub const Proposal = struct {
    entry_id: []const u8,
    source_offset: u32,
    prepared: items.ledger.Prepared,
};

pub fn plan(asset: Asset, packet: items.catalogue.Packet, entry_id: []const u8, facts: Facts, view: items.ledger.View) !Proposal {
    const entry = entryById(asset, entry_id) orelse return error.UnknownItemOperation;
    if (entry.selector != 0 and entry.selector != 1) return error.UseWarehouseDeposit;
    try admit(entry, facts);
    const operation: items.ledger.Op = if (entry.selector == 0) .acquire else .remove;
    return .{
        .entry_id = entry.id,
        .source_offset = entry.offset,
        .prepared = try items.ledger.prepare(packet, view, operation, entry.item_id),
    };
}

pub fn commit(asset: Asset, packet: items.catalogue.Packet, view: *items.ledger.View, proposal: Proposal) !void {
    const entry = entryById(asset, proposal.entry_id) orelse return error.UnknownItemOperation;
    if (entry.offset != proposal.source_offset) return error.MismatchedItemProposal;
    const item = items.catalogue.findBySourceId(packet, entry.source_item_id) orelse return error.UnknownItemIdentity;
    const operation: items.ledger.Op = if (entry.selector == 0) .acquire else if (entry.selector == 1) .remove else return error.UseWarehouseDeposit;
    if (proposal.prepared.operation != operation or proposal.prepared.item_source_id != item.source_item_id)
        return error.MismatchedItemProposal;
    try items.ledger.replay(packet, view, proposal.prepared);
}

pub const DepositProposal = struct {
    entry_id: []const u8,
    source_offset: u32,
    member_index: usize,
    transferred: u8,
    baseline_digest: u64,
    snapshot: party.Snapshot,
};

pub fn planDeposit(asset: Asset, packet: items.catalogue.Packet, entry_id: []const u8, facts: Facts, snapshot: party.Snapshot, catalogue: items.owners.Catalogue) !DepositProposal {
    const entry = entryById(asset, entry_id) orelse return error.UnknownItemOperation;
    if (entry.selector != 2) return error.NotWarehouseDeposit;
    try admit(entry, facts);
    try items.owners.validateSnapshot(packet, snapshot, catalogue);
    const member_index = try items.owners.memberIndex(snapshot, entry.member_id.?);
    var candidate = snapshot;
    const member = &candidate.members[member_index].?;
    var transferred: u8 = 0;
    var slot = member.member.inventory.slots.len;
    while (slot > 0) {
        slot -= 1;
        const stack = member.member.inventory.slots[slot] orelse continue;
        const item = items.catalogue.findById(packet, @tagName(stack.id)) orelse return error.UnknownItemIdentity;
        const eligible = try items.ledger.transferEligible(item, .{
            .identified = stack.identified,
            .worn = items.owners.wearsItem(catalogue, member.*, slot),
        });
        if (!eligible) continue;
        try candidate.storage.deposit(&member.member.inventory, slot);
        transferred += 1;
    }
    return .{
        .entry_id = entry.id,
        .source_offset = entry.offset,
        .member_index = member_index,
        .transferred = transferred,
        .baseline_digest = items.owners.stateDigest(snapshot),
        .snapshot = candidate,
    };
}

pub const Host = struct {
    asset: *const Asset,
    packet: items.catalogue.Packet,
    view: *items.ledger.View,
    story: *const events.StoryState,

    /// Accept one source acquire/remove entry through the canonical proposal
    /// and commit path. Warehouse deposits remain a separate caller.
    pub fn apply(self: *Host, entry_id: []const u8, entity_retained: bool, interaction: bool) !void {
        const proposal = try plan(self.asset.*, self.packet, entry_id, .{
            .story = self.story,
            .entity_retained = entity_retained,
            .interaction = interaction,
        }, self.view.*);
        try commit(self.asset.*, self.packet, self.view, proposal);
    }
};

pub fn commitDeposit(asset: Asset, packet: items.catalogue.Packet, snapshot: *party.Snapshot, catalogue: items.owners.Catalogue, proposal: DepositProposal) !void {
    const entry = entryById(asset, proposal.entry_id) orelse return error.UnknownItemOperation;
    if (entry.selector != 2) return error.NotWarehouseDeposit;
    if (entry.offset != proposal.source_offset) return error.MismatchedItemProposal;
    const member_index = try items.owners.memberIndex(snapshot.*, entry.member_id.?);
    if (proposal.member_index != member_index) return error.MismatchedItemProposal;
    if (items.owners.stateDigest(snapshot.*) != proposal.baseline_digest) return error.StaleBaseline;
    try items.owners.validateSnapshot(packet, proposal.snapshot, catalogue);
    snapshot.* = proposal.snapshot;
}
