//! Semantic resource layout resolver.
//!
//! `consumers.zig` is the only file that reaches the accepted runtime
//! modules (`hq.services.Host`, `hq.tablet.View`).
const std = @import("std");
const data = @import("table.zig");

pub const Resource = enum { tablet, warehouse };

pub const Room = enum {
    castle_vb5b1,
    area_c_vc2,
    area_g_vg1,

    pub fn isCastle(self: Room) bool {
        return self == .castle_vb5b1;
    }
};

pub const FaceResource = struct {
    page: u8,
    cell: u8,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    portrait_index: u8,
};

/// Map a portrait index to its 27-page atlas page and 64x64 quadrant.
pub fn faceResource(portrait_index: u8) ?FaceResource {
    const page = portrait_index >> 2;
    const cell = portrait_index & 3;
    if (page >= data.face_page_count) return null;
    return .{
        .page = page,
        .cell = cell,
        .x = @as(u16, cell & 1) * data.face_quadrant,
        .y = @as(u16, cell >> 1) * data.face_quadrant,
        .width = data.face_quadrant,
        .height = data.face_quadrant,
        .portrait_index = portrait_index,
    };
}

test "portrait identity resolves into the 27-page atlas" {
    const first = faceResource(0).?;
    try std.testing.expectEqual(@as(u8, 0), first.page);
    try std.testing.expectEqual(@as(u8, 0), first.cell);
    try std.testing.expectEqual(@as(u16, 0), first.x);
    try std.testing.expectEqual(@as(u16, 0), first.y);
    const lower_left = faceResource(6).?;
    try std.testing.expectEqual(@as(u8, 1), lower_left.page);
    try std.testing.expectEqual(@as(u8, 2), lower_left.cell);
    try std.testing.expectEqual(@as(u16, 0), lower_left.x);
    try std.testing.expectEqual(@as(u16, 64), lower_left.y);
    try std.testing.expectEqual(@as(u8, 6), lower_left.portrait_index);
    try std.testing.expect(faceResource(108) == null);
}
