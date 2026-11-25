//! Field camera: tile focus, signed pixel offset and the 320x240 clamped scroll.
//!
//! The source uses an 8-pixel focus cell and a 16-pixel section cell.  Both
//! units are named here so a caller cannot mix them silently.

const std = @import("std");
const model = @import("model.zig");

pub const Vec2 = struct { x: i32, y: i32 };
pub const ScreenPoint = @import("battle.zig").ScreenPoint;

pub const Field = struct {
    focus_cell: Vec2,
    offset_px: Vec2,
    scroll_px: Vec2,
    section_cells: Vec2,
    viewport_px: Vec2,
};

pub fn computeScroll(
    entry: model.EntryDef,
    section_cell_px: i32,
    section_cells: Vec2,
    focus_cell: Vec2,
    offset_px: Vec2,
    viewport_px: Vec2,
) Vec2 {
    const focus_px = @as(i32, 1) << entry.cell_shift;
    const raw_x = focus_cell.x * focus_px + offset_px.x - entry.x_subtract_px;
    const raw_y = focus_cell.y * focus_px + offset_px.y - entry.y_subtract_px;
    const max_x = section_cells.x * section_cell_px - viewport_px.x;
    const max_y = section_cells.y * section_cell_px - viewport_px.y;
    return .{ .x = clampAxis(raw_x, max_x), .y = clampAxis(raw_y, max_y) };
}

fn clampAxis(raw: i32, maximum: i32) i32 {
    var value = if (raw < 0) 0 else raw;
    if (maximum < value) value = maximum;
    return value;
}

pub fn recompute(entry: model.EntryDef, section_cell_px: i32, field: *Field) void {
    field.scroll_px = computeScroll(entry, section_cell_px, field.section_cells, field.focus_cell, field.offset_px, field.viewport_px);
}

fn wrapByte(value: i32) i32 {
    return @as(i32, @as(u8, @truncate(@as(u32, @bitCast(value)))));
}

fn signedByte(value: i32) i32 {
    const byte: u8 = @truncate(@as(u32, @bitCast(value)));
    return @as(i8, @bitCast(byte));
}

/// Apply one 5-byte push record exactly as 0x8013FF5C does: focus bytes wrap,
/// offsets are the low byte of mul*frames read back as signed.
pub fn applyPushRecord(entry: model.EntryDef, section_cell_px: i32, field: *Field, record: model.PushRecord) void {
    field.focus_cell.x = wrapByte(field.focus_cell.x + record.dx);
    field.focus_cell.y = wrapByte(field.focus_cell.y + record.dy);
    field.offset_px.x = signedByte(@as(i32, record.xmul) * @as(i32, record.frames));
    field.offset_px.y = signedByte(@as(i32, record.ymul) * @as(i32, record.frames));
    recompute(entry, section_cell_px, field);
}

pub fn pushFrames(record: model.PushRecord) u16 {
    return record.frames;
}

pub fn stepFocus(field: *Field, delta: Vec2) void {
    field.focus_cell.x += delta.x;
    field.focus_cell.y += delta.y;
}

pub fn project(field: Field, world_q12: model.Vec3) ScreenPoint {
    const world_x: f32 = @floatFromInt(world_q12.x >> 12);
    const world_y: f32 = @floatFromInt(world_q12.y >> 12);
    return .{
        .x = world_x - @as(f32, @floatFromInt(field.scroll_px.x)),
        .y = world_y - @as(f32, @floatFromInt(field.scroll_px.y)),
        .depth = 1,
    };
}

pub const Bounds = struct {
    center_q12: model.Vec3,
    half_q12: model.Vec3,
};

pub const ScreenRect = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    framed: bool,
};

pub fn frameRect(field: Field, bounds: Bounds, width_px: i32, height_px: i32) ScreenRect {
    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for ([_]i32{ -1, 1 }) |sx| {
        for ([_]i32{ -1, 1 }) |sy| {
            const p = project(field, .{
                .x = bounds.center_q12.x + sx * bounds.half_q12.x,
                .y = bounds.center_q12.y + sy * bounds.half_q12.y,
                .z = bounds.center_q12.z,
            });
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }
    }
    return .{
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
        .framed = min_x >= 0 and max_x <= @as(f32, @floatFromInt(width_px)) and min_y >= 0 and max_y <= @as(f32, @floatFromInt(height_px)),
    };
}
