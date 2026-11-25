//! Consumers: the accepted hq_services service host and hq_tablet tablet view are the
//! real callers of the derived rows.
//!
//! `tablet` returns a session whose portrait lookup is the hq_tablet view's own reveal
//! result (page/cell) joined to the FACE page descriptor.  `warehouse` admits the
//! AZUKARI overlay only when the caller presents the VC2/VG1 room row that names
//! it, and then only through hq_services's explicitly non-canonical `openOverlay` path.
//! The interactive NPC conversation is still not derived, so production must keep
//! that path closed (see the blocker metadata).
const std = @import("std");
const data = @import("table.zig");
const entry = @import("entry.zig");
const hq = @import("hq");
const hq_services = hq.services;
const hq_tablet = hq.tablet;

pub const Portrait = entry.FaceResource;

pub const TabletSession = struct {
    view: hq_tablet.View,

    /// The hq_tablet reveal (source reveal gate) plus the FACE page/quadrant resource.
    pub fn portrait(self: *const TabletSession, tablet_entry: u8) ?Portrait {
        const reveal = self.view.reveal(tablet_entry) orelse return null;
        const resource = entry.faceResource(reveal.portrait_index) orelse return null;
        return resource;
    }

    pub fn listed(self: *const TabletSession) u16 {
        return self.view.listedCount();
    }
};

pub fn tablet(flags: [data.tablet_entry_count]u8) !TabletSession {
    try entry.tabletEvidence().verify();
    return .{ .view = hq_tablet.loadView(flags) };
}

pub const WarehouseError = error{
    UnknownRoom,
    UnknownOverlay,
    WrongOverlay,
};

/// Admit the AZUKARI overlay entry from a source room row.  The hq_services host keeps
/// its own conditions (npc/service/area/revision) and the canonical caller
/// remains refused there.
pub fn warehouse(
    packet: *const hq_services.Packet,
    room: entry.Room,
    access: hq_services.Access,
    revision: u64,
) WarehouseError!hq_services.OpenResult {
    const evidence = entry.warehouseEvidence(room) orelse return error.UnknownRoom;
    evidence.verify() catch |err| switch (err) {
        error.WrongRoom => return error.UnknownRoom,
        else => return error.UnknownOverlay,
    };
    const overlay = findOverlayBySource(packet) orelse return error.UnknownOverlay;
    if (overlay.canonical) return error.WrongOverlay;
    if (!std.mem.eql(u8, overlay.source, data.azukari_path)) return error.WrongOverlay;
    return hq_services.openOverlay(packet, overlay.id, access, revision);
}

fn findOverlayBySource(packet: *const hq_services.Packet) ?hq_services.OverlayEntry {
    for (packet.overlay_entries) |row| {
        if (std.mem.eql(u8, row.source, data.azukari_path)) return row;
    }
    return null;
}

test "tablet session joins hq_tablet reveal to the FACE page" {
    var flags: [data.tablet_entry_count]u8 = @splat(0x01);
    const session = try tablet(flags);
    const hero = session.portrait(0).?;
    try std.testing.expectEqualStrings("DATA/03_SHIRO/DATA/FACE_01.BIN", hero.path);
    try std.testing.expectEqual(@as(u8, 0), hero.war_plane);
    try std.testing.expectEqual(@as(u16, 64), hero.width);
    // An unrecruited roster hides the row: hq_tablet's reveal gate, not this pack's.
    flags = @splat(0);
    const hidden = try tablet(flags);
    try std.testing.expect(hidden.portrait(0) == null);
}
