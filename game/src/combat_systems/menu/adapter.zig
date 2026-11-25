//! Runtime row builders.  They are the only bridge between a game owner's
//! concrete state (party inventory, storage counts, party members, a service
//! screen) and the generic menu model.  An id the packet does not admit is a
//! typed refusal, never a blank or invented label.

const std = @import("std");
const model = @import("model.zig");
const packet = @import("vocabulary.zig");

pub const Error = error{
    UnknownItem,
    UnknownRoster,
    UnknownList,
    BufferTooSmall,
};

pub const Target = struct {
    id: []const u8,
    label: []const u8,
    enabled: bool = true,
    detail: ?[]const u8 = null,
};

fn isActive(active: []const []const u8, id: []const u8) bool {
    for (active) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

/// Roster rows in the accepted SLUS record order.  `admitted[i]` is the runtime
/// ownership/eligibility bit for roster entry `i`; a shorter slice means the
/// remaining entries are not owned.  Active members are annotated, never moved:
/// the source record order is the list order.
pub fn rosterRows(
    catalogue: *const packet.Packet,
    admitted: []const bool,
    active: []const []const u8,
    out: []model.Row,
) Error![]model.Row {
    var count: usize = 0;
    for (catalogue.roster, 0..) |character, index| {
        if (index >= admitted.len or !admitted[index]) continue;
        if (count >= out.len) return error.BufferTooSmall;
        out[count] = .{
            .id = character.id,
            .label = character.name,
            .detail = if (isActive(active, character.id)) "Active" else "Reserve",
        };
        count += 1;
    }
    return out[0..count];
}

fn itemRow(catalogue: *const packet.Packet, id: []const u8) Error!model.Row {
    const item = for (catalogue.items) |*candidate| {
        if (std.mem.eql(u8, candidate.id, id)) break candidate;
    } else return error.UnknownItem;
    return .{ .id = item.id, .label = item.label };
}

/// Inventory rows.  `ids` is the ordered bag identity list supplied by the
/// owner; duplicate ids are kept (two stacks of the same item are two rows).
pub fn itemRows(catalogue: *const packet.Packet, ids: []const []const u8, out: []model.Row) Error![]model.Row {
    if (ids.len > out.len) return error.BufferTooSmall;
    for (ids, 0..) |id, index| out[index] = try itemRow(catalogue, id);
    return out[0..ids.len];
}

/// Storage rows.  `quantities` is parallel to `ids`; the quantity is carried as
/// a detail string only when the caller supplies a preformatted slice.  The
/// label stays the full item name so long-name clipping remains a view concern.
pub fn storageRows(catalogue: *const packet.Packet, ids: []const []const u8, out: []model.Row) Error![]model.Row {
    return itemRows(catalogue, ids, out);
}

/// Party targets.  The owner supplies enabled/disabled per target (full health,
/// unconscious, invalid effect) and the full label; the id must be a roster
/// identity so a target cannot be an unowned character.
pub fn targetRows(catalogue: *const packet.Packet, targets: []const Target, out: []model.Row) Error![]model.Row {
    if (targets.len > out.len) return error.BufferTooSmall;
    for (targets, 0..) |target, index| {
        const known = for (catalogue.roster) |character| {
            if (std.mem.eql(u8, character.id, target.id)) break true;
        } else false;
        if (!known) return error.UnknownRoster;
        out[index] = .{
            .id = target.id,
            .label = target.label,
            .enabled = target.enabled,
            .detail = target.detail,
        };
    }
    return out[0..targets.len];
}

fn findList(catalogue: *const packet.Packet, key: []const u8) ?*const packet.List {
    for (catalogue.lists) |*list| if (std.mem.eql(u8, list.key, key)) return list;
    for (catalogue.port_lists) |*list| if (std.mem.eql(u8, list.key, key)) return list;
    return null;
}

/// Service rows from the packet.  `enabled` is optional and parallel; when
/// absent every source row is a command and separators stay separators.
pub fn serviceRows(
    catalogue: *const packet.Packet,
    key: []const u8,
    enabled: ?[]const bool,
    out: []model.Row,
) Error![]model.Row {
    const list = findList(catalogue, key) orelse return error.UnknownList;
    if (list.rows.len > out.len) return error.BufferTooSmall;
    if (enabled) |mask| if (mask.len != list.rows.len) return error.BufferTooSmall;
    for (list.rows, 0..) |row, index| {
        out[index] = .{
            .id = if (row.action) |action| action else row.label,
            .label = row.label,
            .role = if (row.role == .separator) .separator else .command,
            .enabled = if (enabled) |mask| mask[index] else true,
        };
    }
    return out[0..list.rows.len];
}

pub fn itemLabel(catalogue: *const packet.Packet, id: []const u8) ?[]const u8 {
    for (catalogue.items) |item| if (std.mem.eql(u8, item.id, id)) return item.label;
    return null;
}

pub fn findCharacter(packet_value: *const packet.Packet, id: []const u8) ?*const packet.Character {
    for (packet_value.roster) |*character_value| {
        if (std.mem.eql(u8, character_value.id, id)) return character_value;
    }
    return null;
}
