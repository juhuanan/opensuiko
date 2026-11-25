//! Entry/resource resolver.
//!
//! Pure data resolution over the generated frontier table (the embedded asset).  Nothing here
//! touches the disc, an original instruction, a window or media: the asset is
//! the source-derived projection and every function refuses a row that is not
//! in it.  `consumers.zig` is the only file that reaches the accepted runtime
//! modules (hq.services.Host, hq.tablet.View).
const std = @import("std");
const data = @import("table.zig");

pub const Resource = enum { tablet, warehouse };

pub const Room = enum {
    castle_vb5b1,
    area_c_vc2,
    area_g_vg1,

    pub fn fileName(self: Room) []const u8 {
        return switch (self) {
            .castle_vb5b1 => data.castle_room_path,
            .area_c_vc2 => data.warehouse_room_paths[0],
            .area_g_vg1 => data.warehouse_room_paths[1],
        };
    }

    pub fn isCastle(self: Room) bool {
        return self == .castle_vb5b1;
    }
};

pub const Error = error{
    WrongRoom,
    ResourceMismatch,
    UnknownRow,
    UnknownModuleOperand,
    UnknownFacePage,
    NotSpecialContent,
};

/// One source row: the room file, its exact descriptor address and the static
/// table index it resolves to.  A caller cannot construct a passing row without
/// the table, and `verify` compares every field.
pub const Evidence = struct {
    resource: Resource,
    room: Room,
    path: []const u8,
    descriptor: u32,
    table_index: u16,
    row_offset: u32,
    slot: u16,

    pub fn verify(self: Evidence) Error!void {
        switch (self.resource) {
            .tablet => {
                if (!self.room.isCastle()) return error.WrongRoom;
                if (self.slot >= data.castle_resources.len) return error.UnknownRow;
                const row = data.castle_resources[self.slot];
                if (!std.mem.eql(u8, row.path, data.stone_path)) return error.ResourceMismatch;
                if (!std.mem.eql(u8, self.path, row.path)) return error.ResourceMismatch;
                if (self.descriptor != row.descriptor) return error.ResourceMismatch;
                if (self.table_index != row.table_index) return error.ResourceMismatch;
                if (self.row_offset != row.offset) return error.ResourceMismatch;
                if (row.descriptor != data.stone_descriptor) return error.ResourceMismatch;
                if (row.table_index != data.stone_table_index) return error.ResourceMismatch;
            },
            .warehouse => {
                if (self.room.isCastle()) return error.WrongRoom;
                const row = warehouseRow(self.room) orelse return error.UnknownRow;
                if (!std.mem.eql(u8, self.path, row.path)) return error.ResourceMismatch;
                if (self.descriptor != row.descriptor) return error.ResourceMismatch;
                if (self.table_index != row.table_index) return error.ResourceMismatch;
                if (self.row_offset != row.row_offset) return error.ResourceMismatch;
                if (row.descriptor != data.azukari_descriptor) return error.ResourceMismatch;
                if (row.table_index != data.azukari_table_index) return error.ResourceMismatch;
                if (!std.mem.eql(u8, row.resource, data.azukari_path)) return error.ResourceMismatch;
            },
        }
    }
};

pub fn warehouseRow(room: Room) ?data.RoomRow {
    for (data.warehouse_rows) |row| {
        if (std.mem.eql(u8, row.path, room.fileName())) return row;
    }
    return null;
}

/// The castle overlay's STONE row (slot 5 of the 62-row run).
pub fn tabletEvidence() Evidence {
    const row = data.castle_resources[5];
    return .{
        .resource = .tablet,
        .room = .castle_vb5b1,
        .path = row.path,
        .descriptor = row.descriptor,
        .table_index = row.table_index,
        .row_offset = row.offset,
        .slot = row.slot,
    };
}

pub fn warehouseEvidence(room: Room) ?Evidence {
    const row = warehouseRow(room) orelse return null;
    return .{
        .resource = .warehouse,
        .room = room,
        .path = row.path,
        .descriptor = row.descriptor,
        .table_index = row.table_index,
        .row_offset = row.row_offset,
        .slot = 0,
    };
}

/// The opcode-0x43 operand -> module entry the room itself carries.  A null
/// table row is a real refusal, not an empty default.
pub fn moduleEntry(operand: u8) Error!u32 {
    if (operand >= data.castle_module_count) return error.UnknownModuleOperand;
    return data.castle_module_entries[operand].entry orelse error.UnknownModuleOperand;
}

pub fn moduleEntryOrNull(operand: u8) ?u32 {
    return moduleEntry(operand) catch null;
}

/// A resource the 16-entry special-content selector can load, or null.
pub fn specialSelector(path: []const u8) ?u8 {
    for (data.special_selectors) |row| {
        if (std.mem.eql(u8, row.path, path)) return row.selector;
    }
    return null;
}

pub fn specialPath(selector: u8) ?[]const u8 {
    for (data.special_selectors) |row| {
        if (row.selector == selector) return row.path;
    }
    return null;
}

pub const FaceResource = struct {
    page: u8,
    cell: u8,
    path: []const u8,
    lba: u32,
    size: u32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    war_plane: u8,
    decoded_bytes: u32,
};

/// The tablet's portrait identity -> FACE page file + 64x64 quadrant.  The
/// tablet asset already carries `portrait_page` (`index >> 2`) and
/// `portrait_cell` (`index & 3`); this is the resource half it leaves open.
pub fn faceResource(portrait_index: u8) ?FaceResource {
    const page = portrait_index >> 2;
    const cell = portrait_index & 3;
    if (page >= data.face_page_count) return null;
    const row = data.face_pages[page];
    if (row.decoded_bytes != data.face_page_bytes) return null;
    return .{
        .page = page,
        .cell = cell,
        .path = row.path,
        .lba = row.lba,
        .size = row.size,
        .x = @as(u16, cell & 1) * data.face_quadrant,
        .y = @as(u16, cell >> 1) * data.face_quadrant,
        .width = data.face_quadrant,
        .height = data.face_quadrant,
        .war_plane = portrait_index,
        .decoded_bytes = row.decoded_bytes,
    };
}

pub fn facePage(page: u8) ?data.FacePage {
    if (page >= data.face_page_count) return null;
    return data.face_pages[page];
}

test "castle row and module table are the frontier table's, not a copy" {
    const evidence = tabletEvidence();
    try evidence.verify();
    try std.testing.expectEqualStrings(data.stone_path, evidence.path);
    try std.testing.expectEqual(@as(u16, 5), evidence.slot);
    try std.testing.expectEqual(@as(u8, 17), data.castle_module_count);
    try std.testing.expectEqual(@as(usize, 17), data.castle_module_entries.len);
    try std.testing.expectEqual(@as(u32, 0x800104c8), try moduleEntry(0));
    try std.testing.expectError(error.UnknownModuleOperand, moduleEntry(1));
    try std.testing.expectError(error.UnknownModuleOperand, moduleEntry(17));
}

test "evidence refuses a different room, row and descriptor" {
    var evidence = tabletEvidence();
    evidence.room = .area_c_vc2;
    try std.testing.expectError(error.WrongRoom, evidence.verify());

    var tampered = tabletEvidence();
    tampered.descriptor = data.stone_descriptor + 8;
    try std.testing.expectError(error.ResourceMismatch, tampered.verify());

    var offset = tabletEvidence();
    offset.row_offset += 4;
    try std.testing.expectError(error.ResourceMismatch, offset.verify());

    var out_of_range = tabletEvidence();
    out_of_range.slot = 200;
    try std.testing.expectError(error.UnknownRow, out_of_range.verify());

    var warehouse = warehouseEvidence(.area_c_vc2).?;
    try warehouse.verify();
    warehouse.room = .castle_vb5b1;
    try std.testing.expectError(error.WrongRoom, warehouse.verify());
}

test "portrait identity resolves into the 27-page atlas" {
    const first = faceResource(0).?;
    try std.testing.expectEqualStrings("DATA/03_SHIRO/DATA/FACE_01.BIN", first.path);
    try std.testing.expectEqual(@as(u16, 0), first.x);
    try std.testing.expectEqual(@as(u16, 0), first.y);
    const lower_left = faceResource(6).?;
    try std.testing.expectEqual(@as(u8, 1), lower_left.page);
    try std.testing.expectEqual(@as(u8, 2), lower_left.cell);
    try std.testing.expectEqual(@as(u16, 0), lower_left.x);
    try std.testing.expectEqual(@as(u16, 64), lower_left.y);
    try std.testing.expectEqual(@as(u16, 6), lower_left.war_plane);
    try std.testing.expect(faceResource(108) == null);
}

test "special-content selector is a closed set" {
    try std.testing.expectEqual(@as(u8, 11), specialSelector("DATA/03_SHIRO/COIN.BIN").?);
    try std.testing.expectEqual(@as(u8, 15), specialSelector("DATA/03_SHIRO/KARUTA.BIN").?);
    try std.testing.expect(specialSelector(data.stone_path) == null);
    try std.testing.expect(specialSelector(data.azukari_path) == null);
    try std.testing.expect(specialPath(15) != null);
}
