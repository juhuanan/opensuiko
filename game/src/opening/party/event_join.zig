//! Source-qualified VA1 0x3C/0x1F party operations over the canonical owner.
const std = @import("std");
const creation = @import("creation.zig");
const party = @import("party.zig");

const same = creation.same;

const SourceSpec = struct {
    id: []const u8,
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
};

const source_specs = [_]SourceSpec{
    .{ .id = "party_op_02", .room = 0, .entity_ids = &.{37}, .stream = 243420, .offset = 243749, .opcode = 0x1F, .selector = 0, .source_character_id = null, .character = null, .family = "load_character_area_template", .execution = "resource_join_contract" },
    .{ .id = "party_op_03", .room = 1, .entity_ids = &.{22}, .stream = 246724, .offset = 246819, .opcode = 0x3C, .selector = 6, .source_character_id = 6, .character = "Pahn", .family = "event_party_add", .execution = "event_join_contract" },
    .{ .id = "party_op_04", .room = 1, .entity_ids = &.{22}, .stream = 246724, .offset = 246876, .opcode = 0x3C, .selector = 1, .source_character_id = 1, .character = "Cleo", .family = "event_party_add", .execution = "event_join_contract" },
    .{ .id = "party_op_05", .room = 1, .entity_ids = &.{ 19, 20, 21 }, .stream = 246880, .offset = 246961, .opcode = 0x3C, .selector = 108, .source_character_id = 108, .character = "Ted", .family = "event_party_add", .execution = "event_join_contract" },
    .{ .id = "party_op_07", .room = 2, .entity_ids = &.{2}, .stream = 250228, .offset = 250278, .opcode = 0x3C, .selector = 108, .source_character_id = 108, .character = "Ted", .family = "event_party_add", .execution = "event_join_contract" },
    .{ .id = "party_op_09", .room = 2, .entity_ids = &.{22}, .stream = 251252, .offset = 251365, .opcode = 0x3C, .selector = 2, .source_character_id = 2, .character = "Gremio", .family = "event_party_add", .execution = "event_join_contract" },
};

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return b != null and std.mem.eql(u8, left, b.?);
    return b == null;
}

pub fn validateOperation(operation: party.Operation) !void {
    const spec = for (source_specs) |candidate| {
        if (std.mem.eql(u8, candidate.id, operation.id)) break candidate;
    } else return error.UnsupportedEventJoin;
    if (!std.mem.eql(u8, operation.source_file, "DATA/01_AREA.A/VA1.BIN") or
        operation.room != spec.room or !std.mem.eql(u8, operation.entity_ids, spec.entity_ids) or
        operation.stream != spec.stream or operation.offset != spec.offset or
        operation.opcode != spec.opcode or operation.selector != spec.selector or
        operation.source_character_id != spec.source_character_id or
        !optionalStringEqual(operation.character, spec.character) or
        !std.mem.eql(u8, operation.family, spec.family) or
        !std.mem.eql(u8, operation.execution, spec.execution) or
        !std.mem.eql(u8, operation.guard, "source ordinary selection and retained construction facts") or
        !std.mem.eql(u8, operation.runtime_state, "source_action")) return error.UnqualifiedEventJoin;
}

pub const RecordSelection = struct {
    roster_index: usize,
    source_character_id: u8,
    member_id: []const u8,
};

pub const AreaResolution = struct {
    area_header_offset: u32,
    header_bias: u8,
    table_offset: u32,
    table_index: u8,
    table_entry_offset: u32,
    template_offset: u32,
    template_copy_bytes: u32,
    template_copy_sha256: []const u8,
    resource: creation.local.Source,
};

pub const Proposal = struct {
    operation: party.Operation,
    owner: creation.Proposal,
    record: ?RecordSelection,
    source_slot: ?u8,
    active_order_index: ?u8,
    area: ?AreaResolution = null,
    resource: ?creation.local.Proposal = null,
};

fn selectedRecord(state: creation.OwnerState, source_character_id: u8, member_id: []const u8) !RecordSelection {
    for (state.roster.members, 0..) |maybe_member, index| {
        const member = maybe_member orelse continue;
        if (std.mem.eql(u8, member.member.id, member_id)) return .{
            .roster_index = index,
            .source_character_id = source_character_id,
            .member_id = member_id,
        };
    }
    return error.PersistentRecordUnavailable;
}

fn areaResolution(template: creation.local.Asset, operation: party.Operation) !AreaResolution {
    if (template.selector != operation.selector or template.table_index < operation.selector)
        return error.UntrustedLocalTemplate;
    return .{
        .area_header_offset = template.area_header_offset,
        .header_bias = template.table_index - operation.selector,
        .table_offset = template.table_offset,
        .table_index = template.table_index,
        .table_entry_offset = try std.math.add(u32, template.table_offset, try std.math.mul(u32, template.table_index, 4)),
        .template_offset = template.template_offset,
        .template_copy_bytes = template.template_copy_bytes,
        .template_copy_sha256 = template.template_copy_sha256,
        .resource = template.resource,
    };
}

fn sameCommand(a: creation.Operation, b: creation.Operation) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .initialize_template => |value| value == b.initialize_template,
        .event_add => |value| value == b.event_add,
        .local_template => |value| same(value, b.local_template),
    };
}

fn sameProposal(a: Proposal, b: Proposal) bool {
    return same(a.operation, b.operation) and sameCommand(a.owner.operation, b.owner.operation) and
        same(a.owner.before, b.owner.before) and same(a.owner.after, b.owner.after) and
        same(a.record, b.record) and a.source_slot == b.source_slot and
        a.active_order_index == b.active_order_index and same(a.area, b.area) and same(a.resource, b.resource);
}

pub fn propose(owner: creation.Owner, context: creation.Context, operation: party.Operation, checkpoint: u64) !Proposal {
    try validateOperation(operation);
    const command: creation.Operation = switch (operation.opcode) {
        0x3C => .{ .event_add = operation.selector },
        0x1F => .{ .local_template = .{
            .room = operation.room,
            .entity = operation.entity_ids[0],
            .offset = operation.offset,
            .selector = operation.selector,
        } },
        else => unreachable,
    };
    const before = owner.state;
    var source_slot: ?u8 = null;
    var resource: ?creation.local.Proposal = null;
    var area: ?AreaResolution = null;
    var character_id = operation.selector;
    var member_id: []const u8 = undefined;
    if (operation.opcode == 0x3C) {
        const source = try creation.sourceFor(operation.selector);
        member_id = source.character_id;
        if (std.mem.indexOfScalar(u8, &before.slots, operation.selector)) |slot| source_slot = @intCast(slot);
    } else {
        character_id = 35;
        member_id = "viktor";
        resource = try creation.local.resolve(context.template, operation.room, operation.entity_ids[0], operation.offset, operation.selector, before.count, before.slots, before.revision, checkpoint);
        source_slot = resource.?.slot;
        area = try areaResolution(context.template, operation);
    }
    const owner_proposal = try owner.propose(context, command, checkpoint);
    const after = owner_proposal.after;
    if (!same(before.roster.members, after.roster.members) or
        !same(before.roster.extras, after.roster.extras) or
        !same(before.initialized, after.initialized) or
        !same(before.recruit_flags, after.recruit_flags)) return error.InvalidEventJoinTransition;
    if (after.count != before.count and after.count != before.count + 1) return error.InvalidEventJoinTransition;
    const record: ?RecordSelection = if (operation.opcode == 0x1F or source_slot != null)
        try selectedRecord(before, character_id, member_id)
    else
        null;
    return .{
        .operation = operation,
        .owner = owner_proposal,
        .record = record,
        .source_slot = source_slot,
        .active_order_index = if (after.count == before.count + 1) before.count else null,
        .area = area,
        .resource = resource,
    };
}

pub fn commit(owner: *creation.Owner, context: creation.Context, operation: party.Operation, proposal: Proposal) !void {
    if (!same(operation, proposal.operation)) return error.StaleEventJoin;
    const canonical = try propose(owner.*, context, operation, proposal.owner.after.checkpoint);
    if (!sameProposal(canonical, proposal)) return error.InvalidEventJoinProposal;
    try owner.commit(context, proposal.owner);
}
