//! Mandatory entry/resource joins at their real consumers.
//!
//! Exports:
//!   * `data` (`table.zig`) -- semantic portrait/tablet layout constants;
//!   * `entry` (`entry.zig`) -- semantic portrait & room layout helpers;
//!   * `consumers` (`consumers.zig`) -- joins to the service host and tablet view.
const std = @import("std");
const hq_services = @import("hq").services;

pub const data = @import("table.zig");
pub const entry = @import("entry.zig");
pub const consumers = @import("consumers.zig");

pub const Resource = entry.Resource;
pub const Room = entry.Room;
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
    try std.testing.expectEqual(@as(u8, 27), data.face_page_count);
    try std.testing.expectEqual(@as(u8, 108), data.tablet_entry_count);
}

test {
    _ = entry;
    _ = consumers;
}
