//! Render-ready views for the canonical entry machine.
//!
//! These helpers return plain data and slices into the host's snapshot; they do
//! not import raylib.  the host can draw them from the existing title view.  Names
//! are always exposed in full: `nameLines` wraps, it never clips, and every
//! `SlotRowView` carries the complete stored name plus the complete party
//! preview so a long name or a full roster is never silently shortened.
const std = @import("std");
const name = @import("name.zig");
const slots = @import("slots.zig");
const setup = @import("setup.zig");
const entry = @import("entry.zig");
const policy = @import("policy.zig");

pub const TitleItem = struct {
    label: []const u8,
    provenance: policy.Provenance,
    selected: bool,
};

pub fn titleItems(state: *const entry.Entry) [policy.rows.len]TitleItem {
    var items: [policy.rows.len]TitleItem = undefined;
    for (policy.rows, 0..) |row, index| {
        items[index] = .{
            .label = row.label,
            .provenance = row.provenance,
            .selected = state.phase == .title and index == state.row,
        };
    }
    return items;
}

pub const SlotRowView = struct {
    index: usize,
    status: slots.Status,
    status_label: []const u8,
    name: []const u8,
    scene: []const u8,
    level: u8,
    seconds: u64,
    roster_total: u16,
    party: []const slots.PartyMember,
    selected: bool,
};

pub fn slotRow(state: *const entry.Entry, index: usize) SlotRowView {
    const info = state.items[index];
    return .{
        .index = index,
        .status = info.status,
        .status_label = slots.statusLabel(info.status),
        .name = info.name,
        .scene = info.scene,
        .level = info.level,
        .seconds = info.seconds,
        .roster_total = info.roster_total,
        .party = info.party,
        .selected = index == state.slot_cursor,
    };
}

pub fn slotRows(state: *const entry.Entry, out: []SlotRowView) !usize {
    if (out.len < state.items.len) return error.RowsTooShort;
    for (state.items, 0..) |_, index| out[index] = slotRow(state, index);
    return state.items.len;
}

/// Wraps the name currently being entered.  The concatenation of the returned
/// slices is exactly `state.name_buf.text()`.
pub fn nameLines(state: *const entry.Entry, width: usize, out: [][]const u8) !usize {
    return name.wrap(state.name_buf.text(), width, out);
}

pub fn namePreview(state: *const entry.Entry) []const u8 {
    return state.name_buf.text();
}

pub const SetupRowView = struct {
    label: []const u8,
    value: []const u8,
    selected: bool,
};

pub const unset_label = "unset";

pub fn setupRows(state: *const entry.Entry) [setup.group_count]SetupRowView {
    var rows: [setup.group_count]SetupRowView = undefined;
    for (setup.groups, 0..) |group, index| {
        const chosen = state.draft.get(group.id);
        rows[index] = .{
            .label = group.label,
            .value = if (chosen) |option| group.choices[option] else unset_label,
            .selected = index == state.setup_row,
        };
    }
    return rows;
}

pub const OverwriteView = struct {
    prompt: []const u8,
    yes: bool,
    slot: usize,
    status: slots.Status,
};

pub fn overwriteView(state: *const entry.Entry) OverwriteView {
    const info = state.items[state.pending_slot];
    return .{
        .prompt = slots.overwriteLabel(slots.overwriteFor(info.status)),
        .yes = state.confirm_yes,
        .slot = state.pending_slot,
        .status = info.status,
    };
}

pub fn notice(state: *const entry.Entry) []const u8 {
    return entry.noticeText(state.notice);
}

/// `H:MM` for a slot's elapsed time; the buffer is caller-owned and the view
/// never depends on an allocator.
pub fn timeLabel(seconds: u64, buffer: *[16]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}:{d:0>2}", .{ seconds / 3600, seconds / 60 % 60 }) catch "?";
}

/// One presentation line per group value, used by tests and by the integrator
/// to prove a full roster preview is not clipped.
pub fn partyNames(party: []const slots.PartyMember, out: [][]const u8) !usize {
    if (out.len < party.len) return error.LinesTooShort;
    for (party, 0..) |member, index| out[index] = member.name;
    return party.len;
}

test "title view marks the source rows and the port extensions" {
    const items = [_]slots.SlotInfo{ .{}, .{}, .{} };
    var state = try entry.Entry.init(&items, .{}, .{}, false);
    const rows = titleItems(&state);
    try std.testing.expectEqualStrings("New game", rows[0].label);
    try std.testing.expectEqual(policy.Provenance.source_observed, rows[0].provenance);
    try std.testing.expect(rows[1].selected);
    state.row = 0;
    try std.testing.expect(titleItems(&state)[0].selected);
    try std.testing.expectEqual(policy.Provenance.port_extension, rows[2].provenance);
}

test "setup view shows unset instead of an invented default" {
    const items = [_]slots.SlotInfo{ .{}, .{}, .{} };
    var state = try entry.Entry.init(&items, .{}, .{}, false);
    state.openSetup(.title);
    const rows = setupRows(&state);
    try std.testing.expectEqualStrings("Message speed", rows[0].label);
    try std.testing.expectEqualStrings(unset_label, rows[0].value);
    _ = state.tick(.{ .right = true });
    try std.testing.expectEqualStrings("Fast", setupRows(&state)[0].value);
}

test "time label is stable" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2:05", timeLabel(7500, &buffer));
}
