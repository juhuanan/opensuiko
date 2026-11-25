//! Source-derived PS1 disc/RAM provenance tables for castle/warehouse/face resources.
//! Kept in tests as reference evidence; runtime uses only semantic portrait layout.
const std = @import("std");
const frontiers = @import("package_host").frontiers;

pub const schema = frontiers.schema;
pub const version = frontiers.version;
pub const asset_sha256 = "2377e678c6c9187aaaa0cc13c36ffdfa15c542d6a4933c4eb6cf214aa944802b";

pub const ResourceRow = struct { slot: u16, table_index: u16, descriptor: u32, offset: u32, path: []const u8, lba: u32, size: u32 };
pub const ModuleEntry = struct { operand: u8, entry: ?u32 };
pub const FacePage = struct { page: u8, path: []const u8, lba: u32, size: u32, decoded_bytes: u32 };
pub const SpecialSelector = struct { selector: u8, table_index: u16, path: []const u8 };
pub const RoomRow = struct { path: []const u8, row_offset: u32, table_index: u16, descriptor: u32, resource: []const u8 };

pub const load_base: u32 = 0x80010000;
pub const stone_path = "DATA/03_SHIRO/STONE.BIN";
pub const azukari_path = "DATA/03_SHIRO/AZUKARI.BIN";
pub const castle_room_path = "DATA/02_AREA.B/VB5B1.BIN";
pub const warehouse_room_paths = [_][]const u8{ "DATA/06_AREA.C/VC2.BIN", "DATA/10_AREA.G/VG1.BIN" };
pub const stone_descriptor: u32 = 0x80045204;
pub const stone_table_index: u16 = 63;
pub const azukari_descriptor: u32 = 0x800451cc;
pub const azukari_table_index: u16 = 56;
pub const face_page_bytes: u32 = frontiers.data.face_page_bytes;
pub const face_quadrant: u16 = frontiers.data.face_quadrant;
pub const face_page_count: u8 = frontiers.data.face_page_count;
pub const tablet_entry_count: u8 = frontiers.data.tablet_entry_count;
pub const tablet_cells_per_page: u8 = frontiers.data.tablet_cells_per_page;

pub const castle_header: u32 = 0x80018afc;
pub const castle_module_table: u32 = 0x80018a4c;
pub const castle_module_count: u8 = 17;
pub const castle_module_entries = [_]ModuleEntry{
    .{ .operand = 0, .entry = 0x800104c8 },
    .{ .operand = 1, .entry = null },
    .{ .operand = 2, .entry = null },
    .{ .operand = 3, .entry = 0x800104dc },
    .{ .operand = 4, .entry = 0x800105c4 },
    .{ .operand = 5, .entry = 0x80010974 },
    .{ .operand = 6, .entry = 0x80010994 },
    .{ .operand = 7, .entry = 0x800109b4 },
    .{ .operand = 8, .entry = null },
    .{ .operand = 9, .entry = null },
    .{ .operand = 10, .entry = 0x800109d4 },
    .{ .operand = 11, .entry = 0x80010ba0 },
    .{ .operand = 12, .entry = 0x80010c44 },
    .{ .operand = 13, .entry = 0x80010cc4 },
    .{ .operand = 14, .entry = 0x800137a4 },
    .{ .operand = 15, .entry = 0x80010e50 },
    .{ .operand = 16, .entry = null },
};

pub const castle_resources = [_]ResourceRow{
    .{ .slot = 0, .table_index = 58, .descriptor = 0x800451dc, .offset = 0x353cc, .path = "DATA/03_SHIRO/BOOKS.BIN", .lba = 63440, .size = 134872 },
    .{ .slot = 1, .table_index = 59, .descriptor = 0x800451e4, .offset = 0x353d0, .path = "DATA/03_SHIRO/COIN.BIN", .lba = 63516, .size = 59536 },
    .{ .slot = 2, .table_index = 60, .descriptor = 0x800451ec, .offset = 0x353d4, .path = "DATA/03_SHIRO/KARUTA.BIN", .lba = 81068, .size = 157380 },
    .{ .slot = 3, .table_index = 61, .descriptor = 0x800451f4, .offset = 0x353d8, .path = "DATA/03_SHIRO/MEL_SEL.BIN", .lba = 81207, .size = 59828 },
    .{ .slot = 4, .table_index = 62, .descriptor = 0x800451fc, .offset = 0x353dc, .path = "DATA/03_SHIRO/SD_TEST.BIN", .lba = 81237, .size = 321332 },
    .{ .slot = 5, .table_index = 63, .descriptor = 0x80045204, .offset = 0x353e0, .path = "DATA/03_SHIRO/STONE.BIN", .lba = 81394, .size = 141092 },
    .{ .slot = 6, .table_index = 64, .descriptor = 0x8004520c, .offset = 0x353e4, .path = "DATA/03_SHIRO/WALL.BIN", .lba = 83703, .size = 149892 },
    .{ .slot = 7, .table_index = 65, .descriptor = 0x80045214, .offset = 0x353e8, .path = "DATA/03_SHIRO/WIN_SEL.BIN", .lba = 86017, .size = 102148 },
    .{ .slot = 8, .table_index = 66, .descriptor = 0x8004521c, .offset = 0x353ec, .path = "DATA/03_SHIRO/DATA/BATH_00.BIN", .lba = 86070, .size = 16547 },
    .{ .slot = 9, .table_index = 67, .descriptor = 0x80045224, .offset = 0x353f0, .path = "DATA/03_SHIRO/DATA/BATH_01.BIN", .lba = 86079, .size = 16514 },
    .{ .slot = 10, .table_index = 68, .descriptor = 0x8004522c, .offset = 0x353f4, .path = "DATA/03_SHIRO/DATA/BATH_02.BIN", .lba = 86088, .size = 8840 },
    .{ .slot = 11, .table_index = 69, .descriptor = 0x80045234, .offset = 0x353f8, .path = "DATA/03_SHIRO/DATA/BATH_03.BIN", .lba = 86093, .size = 14589 },
    .{ .slot = 12, .table_index = 70, .descriptor = 0x8004523c, .offset = 0x353fc, .path = "DATA/03_SHIRO/DATA/BATH_04.BIN", .lba = 86101, .size = 14551 },
    .{ .slot = 13, .table_index = 71, .descriptor = 0x80045244, .offset = 0x35400, .path = "DATA/03_SHIRO/DATA/BATH_05.BIN", .lba = 86109, .size = 7866 },
    .{ .slot = 14, .table_index = 72, .descriptor = 0x8004524c, .offset = 0x35404, .path = "DATA/03_SHIRO/DATA/BATH_10.BIN", .lba = 86113, .size = 16314 },
    .{ .slot = 15, .table_index = 73, .descriptor = 0x80045254, .offset = 0x35408, .path = "DATA/03_SHIRO/DATA/BATH_11.BIN", .lba = 86121, .size = 16348 },
    .{ .slot = 16, .table_index = 74, .descriptor = 0x8004525c, .offset = 0x3540c, .path = "DATA/03_SHIRO/DATA/BATH_12.BIN", .lba = 86129, .size = 8784 },
    .{ .slot = 17, .table_index = 75, .descriptor = 0x80045264, .offset = 0x35410, .path = "DATA/03_SHIRO/DATA/BATH_13.BIN", .lba = 86134, .size = 13303 },
    .{ .slot = 18, .table_index = 76, .descriptor = 0x8004526c, .offset = 0x35414, .path = "DATA/03_SHIRO/DATA/BATH_14.BIN", .lba = 86141, .size = 13184 },
    .{ .slot = 19, .table_index = 77, .descriptor = 0x80045274, .offset = 0x35418, .path = "DATA/03_SHIRO/DATA/BATH_15.BIN", .lba = 86148, .size = 7522 },
    .{ .slot = 20, .table_index = 78, .descriptor = 0x8004527c, .offset = 0x3541c, .path = "DATA/03_SHIRO/DATA/BATH_20.BIN", .lba = 86152, .size = 16450 },
    .{ .slot = 21, .table_index = 79, .descriptor = 0x80045284, .offset = 0x35420, .path = "DATA/03_SHIRO/DATA/BATH_21.BIN", .lba = 86161, .size = 16492 },
    .{ .slot = 22, .table_index = 80, .descriptor = 0x8004528c, .offset = 0x35424, .path = "DATA/03_SHIRO/DATA/BATH_22.BIN", .lba = 86170, .size = 8836 },
    .{ .slot = 23, .table_index = 81, .descriptor = 0x80045294, .offset = 0x35428, .path = "DATA/03_SHIRO/DATA/BATH_23.BIN", .lba = 86175, .size = 13654 },
    .{ .slot = 24, .table_index = 82, .descriptor = 0x8004529c, .offset = 0x3542c, .path = "DATA/03_SHIRO/DATA/BATH_24.BIN", .lba = 86182, .size = 13562 },
    .{ .slot = 25, .table_index = 83, .descriptor = 0x800452a4, .offset = 0x35430, .path = "DATA/03_SHIRO/DATA/BATH_25.BIN", .lba = 86189, .size = 7626 },
    .{ .slot = 26, .table_index = 84, .descriptor = 0x800452ac, .offset = 0x35434, .path = "DATA/03_SHIRO/DATA/BATH_30.BIN", .lba = 86193, .size = 15941 },
    .{ .slot = 27, .table_index = 85, .descriptor = 0x800452b4, .offset = 0x35438, .path = "DATA/03_SHIRO/DATA/BATH_31.BIN", .lba = 86201, .size = 15928 },
    .{ .slot = 28, .table_index = 86, .descriptor = 0x800452bc, .offset = 0x3543c, .path = "DATA/03_SHIRO/DATA/BATH_32.BIN", .lba = 86209, .size = 8655 },
    .{ .slot = 29, .table_index = 87, .descriptor = 0x800452c4, .offset = 0x35440, .path = "DATA/03_SHIRO/DATA/BATH_33.BIN", .lba = 86214, .size = 13319 },
    .{ .slot = 30, .table_index = 88, .descriptor = 0x800452cc, .offset = 0x35444, .path = "DATA/03_SHIRO/DATA/BATH_34.BIN", .lba = 86221, .size = 12788 },
    .{ .slot = 31, .table_index = 89, .descriptor = 0x800452d4, .offset = 0x35448, .path = "DATA/03_SHIRO/DATA/BATH_35.BIN", .lba = 86228, .size = 7643 },
    .{ .slot = 32, .table_index = 90, .descriptor = 0x800452dc, .offset = 0x3544c, .path = "DATA/03_SHIRO/DATA/BOOK_0.BIN", .lba = 86232, .size = 7699 },
    .{ .slot = 33, .table_index = 91, .descriptor = 0x800452e4, .offset = 0x35450, .path = "DATA/03_SHIRO/DATA/BOOK_1.BIN", .lba = 86236, .size = 7497 },
    .{ .slot = 34, .table_index = 92, .descriptor = 0x800452ec, .offset = 0x35454, .path = "DATA/03_SHIRO/DATA/BOOK_2.BIN", .lba = 86240, .size = 6699 },
    .{ .slot = 35, .table_index = 93, .descriptor = 0x800452f4, .offset = 0x35458, .path = "DATA/03_SHIRO/DATA/BOOK_3.BIN", .lba = 86244, .size = 7975 },
    .{ .slot = 36, .table_index = 94, .descriptor = 0x800452fc, .offset = 0x3545c, .path = "DATA/03_SHIRO/DATA/BOOK_4.BIN", .lba = 86248, .size = 7585 },
    .{ .slot = 37, .table_index = 95, .descriptor = 0x80045304, .offset = 0x35460, .path = "DATA/03_SHIRO/DATA/BOOK_5.BIN", .lba = 86252, .size = 5417 },
    .{ .slot = 38, .table_index = 96, .descriptor = 0x8004530c, .offset = 0x35464, .path = "DATA/03_SHIRO/DATA/CURIO_0.BIN", .lba = 86255, .size = 7699 },
    .{ .slot = 39, .table_index = 97, .descriptor = 0x80045314, .offset = 0x35468, .path = "DATA/03_SHIRO/DATA/FACE_01.BIN", .lba = 86259, .size = 11664 },
    .{ .slot = 40, .table_index = 98, .descriptor = 0x8004531c, .offset = 0x3546c, .path = "DATA/03_SHIRO/DATA/FACE_02.BIN", .lba = 86265, .size = 11288 },
    .{ .slot = 41, .table_index = 99, .descriptor = 0x80045324, .offset = 0x35470, .path = "DATA/03_SHIRO/DATA/FACE_03.BIN", .lba = 86271, .size = 11492 },
    .{ .slot = 42, .table_index = 100, .descriptor = 0x8004532c, .offset = 0x35474, .path = "DATA/03_SHIRO/DATA/FACE_04.BIN", .lba = 86277, .size = 11495 },
    .{ .slot = 43, .table_index = 101, .descriptor = 0x80045334, .offset = 0x35478, .path = "DATA/03_SHIRO/DATA/FACE_05.BIN", .lba = 86283, .size = 10734 },
    .{ .slot = 44, .table_index = 102, .descriptor = 0x8004533c, .offset = 0x3547c, .path = "DATA/03_SHIRO/DATA/FACE_06.BIN", .lba = 86289, .size = 11395 },
    .{ .slot = 45, .table_index = 103, .descriptor = 0x80045344, .offset = 0x35480, .path = "DATA/03_SHIRO/DATA/FACE_07.BIN", .lba = 86295, .size = 11035 },
    .{ .slot = 46, .table_index = 104, .descriptor = 0x8004534c, .offset = 0x35484, .path = "DATA/03_SHIRO/DATA/FACE_08.BIN", .lba = 86301, .size = 10541 },
    .{ .slot = 47, .table_index = 105, .descriptor = 0x80045354, .offset = 0x35488, .path = "DATA/03_SHIRO/DATA/FACE_09.BIN", .lba = 86307, .size = 10876 },
    .{ .slot = 48, .table_index = 106, .descriptor = 0x8004535c, .offset = 0x3548c, .path = "DATA/03_SHIRO/DATA/FACE_10.BIN", .lba = 86313, .size = 11289 },
    .{ .slot = 49, .table_index = 107, .descriptor = 0x80045364, .offset = 0x35490, .path = "DATA/03_SHIRO/DATA/FACE_11.BIN", .lba = 86319, .size = 11919 },
    .{ .slot = 50, .table_index = 108, .descriptor = 0x8004536c, .offset = 0x35494, .path = "DATA/03_SHIRO/DATA/FACE_12.BIN", .lba = 86325, .size = 11636 },
    .{ .slot = 51, .table_index = 109, .descriptor = 0x80045374, .offset = 0x35498, .path = "DATA/03_SHIRO/DATA/FACE_13.BIN", .lba = 86331, .size = 10994 },
    .{ .slot = 52, .table_index = 110, .descriptor = 0x8004537c, .offset = 0x3549c, .path = "DATA/03_SHIRO/DATA/FACE_14.BIN", .lba = 86337, .size = 10829 },
    .{ .slot = 53, .table_index = 111, .descriptor = 0x80045384, .offset = 0x354a0, .path = "DATA/03_SHIRO/DATA/FACE_15.BIN", .lba = 86343, .size = 10953 },
    .{ .slot = 54, .table_index = 112, .descriptor = 0x8004538c, .offset = 0x354a4, .path = "DATA/03_SHIRO/DATA/FACE_16.BIN", .lba = 86349, .size = 11070 },
    .{ .slot = 55, .table_index = 113, .descriptor = 0x80045394, .offset = 0x354a8, .path = "DATA/03_SHIRO/DATA/FACE_17.BIN", .lba = 86355, .size = 11285 },
    .{ .slot = 56, .table_index = 114, .descriptor = 0x8004539c, .offset = 0x354ac, .path = "DATA/03_SHIRO/DATA/FACE_18.BIN", .lba = 86361, .size = 11257 },
    .{ .slot = 57, .table_index = 115, .descriptor = 0x800453a4, .offset = 0x354b0, .path = "DATA/03_SHIRO/DATA/FACE_19.BIN", .lba = 86367, .size = 10585 },
    .{ .slot = 58, .table_index = 116, .descriptor = 0x800453ac, .offset = 0x354b4, .path = "DATA/03_SHIRO/DATA/FACE_20.BIN", .lba = 86373, .size = 11366 },
    .{ .slot = 59, .table_index = 117, .descriptor = 0x800453b4, .offset = 0x354b8, .path = "DATA/03_SHIRO/DATA/FACE_21.BIN", .lba = 86379, .size = 10798 },
    .{ .slot = 60, .table_index = 118, .descriptor = 0x800453bc, .offset = 0x354bc, .path = "DATA/03_SHIRO/DATA/FACE_22.BIN", .lba = 86385, .size = 10754 },
    .{ .slot = 61, .table_index = 119, .descriptor = 0x800453c4, .offset = 0x354c0, .path = "DATA/03_SHIRO/DATA/FACE_23.BIN", .lba = 86391, .size = 10548 },
};

pub const face_pages = [_]FacePage{
    .{ .page = 0, .path = "DATA/03_SHIRO/DATA/FACE_01.BIN", .lba = 86259, .size = 11664, .decoded_bytes = 16384 },
    .{ .page = 1, .path = "DATA/03_SHIRO/DATA/FACE_02.BIN", .lba = 86265, .size = 11288, .decoded_bytes = 16384 },
    .{ .page = 2, .path = "DATA/03_SHIRO/DATA/FACE_03.BIN", .lba = 86271, .size = 11492, .decoded_bytes = 16384 },
    .{ .page = 3, .path = "DATA/03_SHIRO/DATA/FACE_04.BIN", .lba = 86277, .size = 11495, .decoded_bytes = 16384 },
    .{ .page = 4, .path = "DATA/03_SHIRO/DATA/FACE_05.BIN", .lba = 86283, .size = 10734, .decoded_bytes = 16384 },
    .{ .page = 5, .path = "DATA/03_SHIRO/DATA/FACE_06.BIN", .lba = 86289, .size = 11395, .decoded_bytes = 16384 },
    .{ .page = 6, .path = "DATA/03_SHIRO/DATA/FACE_07.BIN", .lba = 86295, .size = 11035, .decoded_bytes = 16384 },
    .{ .page = 7, .path = "DATA/03_SHIRO/DATA/FACE_08.BIN", .lba = 86301, .size = 10541, .decoded_bytes = 16384 },
    .{ .page = 8, .path = "DATA/03_SHIRO/DATA/FACE_09.BIN", .lba = 86307, .size = 10876, .decoded_bytes = 16384 },
    .{ .page = 9, .path = "DATA/03_SHIRO/DATA/FACE_10.BIN", .lba = 86313, .size = 11289, .decoded_bytes = 16384 },
    .{ .page = 10, .path = "DATA/03_SHIRO/DATA/FACE_11.BIN", .lba = 86319, .size = 11919, .decoded_bytes = 16384 },
    .{ .page = 11, .path = "DATA/03_SHIRO/DATA/FACE_12.BIN", .lba = 86325, .size = 11636, .decoded_bytes = 16384 },
    .{ .page = 12, .path = "DATA/03_SHIRO/DATA/FACE_13.BIN", .lba = 86331, .size = 10994, .decoded_bytes = 16384 },
    .{ .page = 13, .path = "DATA/03_SHIRO/DATA/FACE_14.BIN", .lba = 86337, .size = 10829, .decoded_bytes = 16384 },
    .{ .page = 14, .path = "DATA/03_SHIRO/DATA/FACE_15.BIN", .lba = 86343, .size = 10953, .decoded_bytes = 16384 },
    .{ .page = 15, .path = "DATA/03_SHIRO/DATA/FACE_16.BIN", .lba = 86349, .size = 11070, .decoded_bytes = 16384 },
    .{ .page = 16, .path = "DATA/03_SHIRO/DATA/FACE_17.BIN", .lba = 86355, .size = 11285, .decoded_bytes = 16384 },
    .{ .page = 17, .path = "DATA/03_SHIRO/DATA/FACE_18.BIN", .lba = 86361, .size = 11257, .decoded_bytes = 16384 },
    .{ .page = 18, .path = "DATA/03_SHIRO/DATA/FACE_19.BIN", .lba = 86367, .size = 10585, .decoded_bytes = 16384 },
    .{ .page = 19, .path = "DATA/03_SHIRO/DATA/FACE_20.BIN", .lba = 86373, .size = 11366, .decoded_bytes = 16384 },
    .{ .page = 20, .path = "DATA/03_SHIRO/DATA/FACE_21.BIN", .lba = 86379, .size = 10798, .decoded_bytes = 16384 },
    .{ .page = 21, .path = "DATA/03_SHIRO/DATA/FACE_22.BIN", .lba = 86385, .size = 10754, .decoded_bytes = 16384 },
    .{ .page = 22, .path = "DATA/03_SHIRO/DATA/FACE_23.BIN", .lba = 86391, .size = 10548, .decoded_bytes = 16384 },
    .{ .page = 23, .path = "DATA/03_SHIRO/DATA/FACE_24.BIN", .lba = 86397, .size = 11348, .decoded_bytes = 16384 },
    .{ .page = 24, .path = "DATA/03_SHIRO/DATA/FACE_25.BIN", .lba = 86403, .size = 9740, .decoded_bytes = 16384 },
    .{ .page = 25, .path = "DATA/03_SHIRO/DATA/FACE_26.BIN", .lba = 86408, .size = 11256, .decoded_bytes = 16384 },
    .{ .page = 26, .path = "DATA/03_SHIRO/DATA/FACE_27.BIN", .lba = 86414, .size = 11546, .decoded_bytes = 16384 },
};

pub const special_selectors = [_]SpecialSelector{
    .{ .selector = 0, .table_index = 336, .path = "DATA/16_WAR/WAR_KUWA.BIN" },
    .{ .selector = 1, .table_index = 334, .path = "DATA/16_WAR/WAR_GARA.BIN" },
    .{ .selector = 2, .table_index = 338, .path = "DATA/16_WAR/WAR_SCA1.BIN" },
    .{ .selector = 3, .table_index = 339, .path = "DATA/16_WAR/WAR_SCA2.BIN" },
    .{ .selector = 4, .table_index = 341, .path = "DATA/16_WAR/WAR_TEO1.BIN" },
    .{ .selector = 5, .table_index = 342, .path = "DATA/16_WAR/WAR_TEO2.BIN" },
    .{ .selector = 6, .table_index = 335, .path = "DATA/16_WAR/WAR_KITA.BIN" },
    .{ .selector = 7, .table_index = 340, .path = "DATA/16_WAR/WAR_SHAS.BIN" },
    .{ .selector = 8, .table_index = 337, .path = "DATA/16_WAR/WAR_LAST.BIN" },
    .{ .selector = 9, .table_index = 4, .path = "DATA/01_AREA.A/DRAGON0.BIN" },
    .{ .selector = 10, .table_index = 229, .path = "DATA/05_BATLE/GAMEOVER.BIN" },
    .{ .selector = 11, .table_index = 59, .path = "DATA/03_SHIRO/COIN.BIN" },
    .{ .selector = 12, .table_index = 65, .path = "DATA/03_SHIRO/WIN_SEL.BIN" },
    .{ .selector = 13, .table_index = 61, .path = "DATA/03_SHIRO/MEL_SEL.BIN" },
    .{ .selector = 14, .table_index = 62, .path = "DATA/03_SHIRO/SD_TEST.BIN" },
    .{ .selector = 15, .table_index = 60, .path = "DATA/03_SHIRO/KARUTA.BIN" },
};

pub const warehouse_rows = [_]RoomRow{
    .{ .path = "DATA/06_AREA.C/VC2.BIN", .row_offset = 0x35250, .table_index = 56, .descriptor = 0x800451cc, .resource = "DATA/03_SHIRO/AZUKARI.BIN" },
    .{ .path = "DATA/10_AREA.G/VG1.BIN", .row_offset = 0x35214, .table_index = 56, .descriptor = 0x800451cc, .resource = "DATA/03_SHIRO/AZUKARI.BIN" },
};

pub const Error = error{
    WrongRoom,
    ResourceMismatch,
    UnknownRow,
    UnknownModuleOperand,
};

pub fn roomFileName(room: frontiers.Room) []const u8 {
    return switch (room) {
        .castle_vb5b1 => castle_room_path,
        .area_c_vc2 => warehouse_room_paths[0],
        .area_g_vg1 => warehouse_room_paths[1],
    };
}

pub const Evidence = struct {
    resource: frontiers.Resource,
    room: frontiers.Room,
    path: []const u8,
    descriptor: u32,
    table_index: u16,
    row_offset: u32,
    slot: u16,

    pub fn verify(self: Evidence) Error!void {
        switch (self.resource) {
            .tablet => {
                if (!self.room.isCastle()) return error.WrongRoom;
                if (self.slot >= castle_resources.len) return error.UnknownRow;
                const row = castle_resources[self.slot];
                if (!std.mem.eql(u8, row.path, stone_path)) return error.ResourceMismatch;
                if (!std.mem.eql(u8, self.path, row.path)) return error.ResourceMismatch;
                if (self.descriptor != row.descriptor) return error.ResourceMismatch;
                if (self.table_index != row.table_index) return error.ResourceMismatch;
                if (self.row_offset != row.offset) return error.ResourceMismatch;
                if (row.descriptor != stone_descriptor) return error.ResourceMismatch;
                if (row.table_index != stone_table_index) return error.ResourceMismatch;
            },
            .warehouse => {
                if (self.room.isCastle()) return error.WrongRoom;
                const row = warehouseRow(self.room) orelse return error.UnknownRow;
                if (!std.mem.eql(u8, self.path, row.path)) return error.ResourceMismatch;
                if (self.descriptor != row.descriptor) return error.ResourceMismatch;
                if (self.table_index != row.table_index) return error.ResourceMismatch;
                if (self.row_offset != row.row_offset) return error.ResourceMismatch;
                if (row.descriptor != azukari_descriptor) return error.ResourceMismatch;
                if (row.table_index != azukari_table_index) return error.ResourceMismatch;
                if (!std.mem.eql(u8, row.resource, azukari_path)) return error.ResourceMismatch;
            },
        }
    }
};

pub fn warehouseRow(room: frontiers.Room) ?RoomRow {
    for (warehouse_rows) |row| {
        if (std.mem.eql(u8, row.path, roomFileName(room))) return row;
    }
    return null;
}

pub fn tabletEvidence() Evidence {
    const row = castle_resources[5];
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

pub fn warehouseEvidence(room: frontiers.Room) ?Evidence {
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

pub fn moduleEntry(operand: u8) Error!u32 {
    if (operand >= castle_module_count) return error.UnknownModuleOperand;
    return castle_module_entries[operand].entry orelse error.UnknownModuleOperand;
}

pub fn moduleEntryOrNull(operand: u8) ?u32 {
    return moduleEntry(operand) catch null;
}

pub fn specialSelector(path: []const u8) ?u8 {
    for (special_selectors) |row| {
        if (std.mem.eql(u8, row.path, path)) return row.selector;
    }
    return null;
}

pub fn specialPath(selector: u8) ?[]const u8 {
    for (special_selectors) |row| {
        if (row.selector == selector) return row.path;
    }
    return null;
}

pub fn facePage(page: u8) ?FacePage {
    if (page >= face_page_count) return null;
    return face_pages[page];
}
