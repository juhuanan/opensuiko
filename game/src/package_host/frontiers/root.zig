//! Mandatory entry/resource joins at their real consumers.
//!
//! Exports:
//!   * `data` (`table.zig`) -- source-derived entry/resource table
//!     (static overlay table, special-content selector, room rows, FACE pages);
//!   * `entry` (`entry.zig`) -- pure resolution/refusal over that table;
//!   * `consumers` (`consumers.zig`) -- joins to the service host and tablet
//!     view.
//!
//! It does not implement the field object that opens the tablet, the AZUKARI NPC
//! conversation, HQ doors, war, media acceptance or any Opening-Ending route/quest.
//! Those stay typed blockers in the data and the report.
const std = @import("std");
const hq_services = @import("hq").services;

pub const data = @import("table.zig");
pub const entry = @import("entry.zig");

pub const consumers = @import("consumers.zig");

pub const Resource = entry.Resource;
pub const Room = entry.Room;
pub const Evidence = entry.Evidence;
pub const FaceResource = entry.FaceResource;
pub const TabletSession = consumers.TabletSession;

pub const version = data.version;
pub const schema = data.schema;

pub fn tablet(flags: [data.tablet_entry_count]u8) !TabletSession {
    return consumers.tablet(flags);
}

pub fn warehouse(
    packet: *const hq_services.Packet,
    room: Room,
    access: hq_services.Access,
    revision: u64,
) consumers.WarehouseError!hq_services.OpenResult {
    return consumers.warehouse(packet, room, access, revision);
}

test "frontiers identity" {
    try std.testing.expectEqualStrings("suikoden-frontiers/1", schema);
    try std.testing.expectEqualStrings("frontiers.1", version);
    try std.testing.expectEqual(@as(usize, 62), data.castle_resources.len);
    try std.testing.expectEqual(@as(usize, 27), data.face_pages.len);
    try std.testing.expectEqual(@as(usize, 16), data.special_selectors.len);
    try std.testing.expectEqual(@as(usize, 2), data.warehouse_rows.len);
}

test {
    _ = entry;
    _ = consumers;
}
