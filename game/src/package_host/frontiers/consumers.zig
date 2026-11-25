//! Consumers: the accepted `hq.services` host and `hq.tablet` view.
//!
//! `tablet` returns a session whose portrait lookup joins the `hq.tablet` reveal
//! result (page/cell) to the semantic portrait atlas coordinates.  `warehouse`
//! admits the warehouse overlay only for non-castle warehouse rooms through
//! `hq.services`'s explicitly non-canonical `openOverlay` path.
const std = @import("std");
const data = @import("table.zig");
const entry = @import("entry.zig");
const hq = @import("hq");
const hq_services = hq.services;
const hq_tablet = hq.tablet;

pub const Portrait = entry.FaceResource;

pub const TabletSession = struct {
    view: hq_tablet.View,

    pub fn portrait(self: *const TabletSession, tablet_entry: u8) ?Portrait {
        const reveal = self.view.reveal(tablet_entry) orelse return null;
        return entry.faceResource(reveal.portrait_index);
    }

    pub fn listed(self: *const TabletSession) u16 {
        return self.view.listedCount();
    }
};

pub fn tablet(flags: [data.tablet_entry_count]u8) !TabletSession {
    return .{ .view = hq_tablet.loadView(flags) };
}

pub const WarehouseError = error{
    UnknownRoom,
    UnknownOverlay,
    WrongOverlay,
};

pub fn warehouse(
    packet: *const hq_services.Packet,
    room: entry.Room,
    access: hq_services.Access,
    revision: u64,
) WarehouseError!hq_services.OpenResult {
    if (room.isCastle()) return error.UnknownRoom;
    const overlay = findWarehouseOverlay(packet) orelse return error.UnknownOverlay;
    if (overlay.canonical) return error.WrongOverlay;
    return hq_services.openOverlay(packet, overlay.id, access, revision);
}

fn findWarehouseOverlay(packet: *const hq_services.Packet) ?hq_services.OverlayEntry {
    for (packet.overlay_entries) |row| {
        if (row.service == .warehouse) return row;
    }
    return null;
}

test "tablet session joins hq_tablet reveal to the 27-page atlas" {
    var flags: [data.tablet_entry_count]u8 = @splat(0x01);
    const session = try tablet(flags);
    const hero = session.portrait(0).?;
    try std.testing.expectEqual(@as(u8, 0), hero.page);
    try std.testing.expectEqual(@as(u8, 0), hero.cell);
    try std.testing.expectEqual(@as(u8, 0), hero.portrait_index);
    try std.testing.expectEqual(@as(u16, 64), hero.width);
    // An unrecruited roster hides the row: hq_tablet's reveal gate, not this pack's.
    flags = @splat(0);
    const hidden = try tablet(empty_flags: {
        break :empty_flags flags;
    });
    try std.testing.expect(hidden.portrait(0) == null);
}
