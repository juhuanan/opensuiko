const std = @import("std");

pub const schema = "suikoden-opening-roster-ops/1";

pub const Boot = struct {
    template_sha256: []const u8,
    party_slots: [6]u8,
    party_order: [6]u8,
    recruit_flags: [108]u8,
    recruit_flags_sha256: []const u8,
};
pub const Operation = struct {
    id: []const u8,
    source_file: []const u8,
    room: u8,
    entity_ids: []const u8,
    stream: u32,
    offset: u32,
    opcode: u8,
    selector: u8,
    source_character_id: ?u8,
    character: ?[]const u8,
    family: []const u8,
    execution: []const u8,
    guard: []const u8,
    runtime_state: []const u8,
};
pub const Coverage = struct {
    operations: u16,
    source_actions: u16,
    typed_blockers: u16,
    event_party_add: u16,
    resource_loads: u16,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    boot: Boot,
    operations: []const Operation,
    coverage: Coverage,
};

pub const RecordRule = enum { select_existing };
pub const RecruitRule = enum { unchanged };
pub const EventJoin = struct {
    source_character_id: u8,
    record: RecordRule = .select_existing,
    slot: enum { matching_loaded_slot } = .matching_loaded_slot,
    missing_slot: enum { area_sync_only } = .area_sync_only,
    recruit_bitmap: RecruitRule = .unchanged,
};
pub const ResourceJoin = struct {
    selector: u8,
    record: RecordRule = .select_existing,
    slot: enum { first_free } = .first_free,
    area_table: enum { header_bias_index } = .header_bias_index,
    recruit_bitmap: RecruitRule = .unchanged,
};
pub const Decision = union(enum) {
    source_action: []const u8,
    event_join: EventJoin,
    resource_join: ResourceJoin,
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
        return error.InvalidPartySchema;
    if (asset.boot.template_sha256.len != 64 or asset.boot.recruit_flags_sha256.len != 64 or
        asset.boot.party_slots[0] != 8 or asset.boot.party_order[0] != 0)
        return error.InvalidPartyBoot;
    for (asset.boot.party_slots[1..]) |slot| if (slot != 0xFF) return error.InvalidPartyBoot;
    for (asset.boot.party_order[1..]) |slot| if (slot != 0xFE) return error.InvalidPartyBoot;
    for (asset.boot.recruit_flags) |flag| if (flag != 0) return error.UnexpectedBootRecruitment;
    var actions: usize = 0;
    var blockers: usize = 0;
    var joins: usize = 0;
    var loads: usize = 0;
    for (asset.operations, 0..) |operation, index| {
        if (operation.id.len == 0 or operation.stream == 0 or operation.entity_ids.len == 0)
            return error.InvalidPartyOperation;
        for (asset.operations[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, operation.id) or
                (earlier.stream == operation.stream and earlier.offset == operation.offset))
                return error.DuplicatePartyOperation;
        }
        if (operation.source_character_id) |cid| {
            if (cid > 109 or operation.character == null) return error.InvalidPartyCharacter;
        }
        switch (operation.opcode) {
            0x3C => {
                joins += 1;
                if (!std.mem.eql(u8, operation.family, "event_party_add") or
                    !std.mem.eql(u8, operation.execution, "event_join_contract") or
                    !std.mem.eql(u8, operation.runtime_state, "source_action"))
                    return error.InvalidPartyOperation;
            },
            0x1F => {
                loads += 1;
                if (!std.mem.eql(u8, operation.family, "load_character_area_template") or
                    !std.mem.eql(u8, operation.execution, "resource_join_contract") or
                    !std.mem.eql(u8, operation.runtime_state, "source_action"))
                    return error.InvalidPartyOperation;
            },
            0x20, 0x36 => {
                if (!std.mem.startsWith(u8, operation.execution, "roster_") or
                    !std.mem.eql(u8, operation.runtime_state, "source_action"))
                    return error.InvalidPartyOperation;
            },
            else => return error.InvalidPartyOperation,
        }
        if (std.mem.eql(u8, operation.runtime_state, "source_action")) {
            actions += 1;
        } else if (std.mem.eql(u8, operation.runtime_state, "typed_blocker")) {
            blockers += 1;
        } else return error.InvalidPartyOperation;
    }
    if (asset.coverage.operations != asset.operations.len or
        asset.coverage.source_actions != actions or asset.coverage.typed_blockers != blockers or
        asset.coverage.event_party_add != joins or asset.coverage.resource_loads != loads)
        return error.InvalidPartyCoverage;
}

pub fn plan(operation: Operation) Decision {
    if (operation.opcode == 0x3C) return .{ .event_join = .{ .source_character_id = operation.source_character_id orelse 0xFF } };
    if (operation.opcode == 0x1F) return .{ .resource_join = .{ .selector = operation.selector } };
    return .{ .source_action = operation.family };
}
