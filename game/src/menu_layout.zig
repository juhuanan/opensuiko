//! Named pause-menu frames. The values are the existing layout, now explicit
//! so the remaining source-geometry gaps are visible in one place.

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const top = Rect{ .x = 8, .y = 8, .w = 496, .h = 34 };
pub const commands = Rect{ .x = 8, .y = 48, .w = 142, .h = 338 };
pub const room = Rect{ .x = 158, .y = 360, .w = 344, .h = 26 };
pub const detail = Rect{ .x = 158, .y = 48, .w = 346, .h = 338 };
pub const detail_344 = Rect{ .x = 158, .y = 48, .w = 344, .h = 338 };
pub const list = Rect{ .x = 158, .y = 48, .w = 344, .h = 306 };
pub const dialog = Rect{ .x = 64, .y = 150, .w = 384, .h = 140 };
pub const notice = Rect{ .x = 32, .y = 166, .w = 448, .h = 116 };
pub const confirm = Rect{ .x = 78, .y = 136, .w = 356, .h = 164 };
pub const new_game = Rect{ .x = 78, .y = 126, .w = 356, .h = 184 };
pub const wide = Rect{ .x = 30, .y = 55, .w = 452, .h = 320 };
pub const full = Rect{ .x = 8, .y = 48, .w = 494, .h = 338 };
pub const item_panel = Rect{ .x = 160, .y = 48, .w = 342, .h = 338 };

pub fn party(index: usize) Rect {
    return .{ .x = 158 + @as(i32, @intCast(index % 2)) * 174, .y = 48 + @as(i32, @intCast(index / 2)) * 104, .w = 170, .h = 98 };
}
