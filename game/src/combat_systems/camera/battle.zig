//! Battle camera math and interpolation, ported from the source routines.
//!
//! The block is Q12 (raw >> 12 is a world unit); the GTE translation is words
//! 6-8 and the position words are the look-at point whose projected screen
//! coordinate is cancelled by the scene scroll.  The package never picks a
//! preset: every entry point takes an id or a packet preset index.

const std = @import("std");
const model = @import("model.zig");
const q12 = @import("fixed_q12");

pub const Vec2f = struct { x: f32, y: f32 };
pub const ScreenPoint = struct { x: f32, y: f32, depth: f32 };

pub const Ortho2D = struct {
    width_px: i32,
    height_px: i32,
};

pub const Perspective = struct {
    focal_length_px: i32,
    center_x_px: i32,
    center_y_px: i32,
    gte_ofx: i32,
    gte_ofy: i32,
    depth_min: i32,
    width_px: i32,
    height_px: i32,
};

pub const Projection = union(enum) {
    ortho_2d: Ortho2D,
    perspective: Perspective,
};

pub const Battle = struct {
    live_raw: [12]i32,
    target_raw: [12]i32,
    timers: [4]i32 = .{ 0, 0, 0, 0 },
    deltas: [12]i32 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    scene_scroll: Vec2f = .{ .x = 0, .y = 0 },
    shake_px: Vec2f = .{ .x = 0, .y = 0 },
};

pub const Interpolation = struct {
    timers: [4]i32,
    deltas: [12]i32,
};

pub fn rawFromBlock(block: model.Block) [12]i32 {
    return .{
        block.position.x,    block.position.y,    block.position.z,
        block.angles.x,      block.angles.y,      block.angles.z,
        block.translation.x, block.translation.y, block.translation.z,
        block.scale.x,       block.scale.y,       block.scale.z,
    };
}

pub fn blockFromRaw(raw: [12]i32) model.Block {
    return .{
        .position = floorQ12Vector(raw[0..3].*),
        .angles = floorQ12Vector(raw[3..6].*),
        .translation = floorQ12Vector(raw[6..9].*),
        .scale = floorQ12Vector(raw[9..12].*),
    };
}

fn floorQ12Vector(raw: [3]i32) model.Vec3 {
    return .{ .x = q12.floorToInt(raw[0]), .y = q12.floorToInt(raw[1]), .z = q12.floorToInt(raw[2]) };
}

pub fn blockFromDef(def: model.BlockDef) model.Block {
    return .{
        .position = .{ .x = def.position[0], .y = def.position[1], .z = def.position[2] },
        .angles = .{ .x = def.angles[0], .y = def.angles[1], .z = def.angles[2] },
        .translation = .{ .x = def.translation[0], .y = def.translation[1], .z = def.translation[2] },
        .scale = .{ .x = def.scale[0], .y = def.scale[1], .z = def.scale[2] },
    };
}

fn sinCos(angle: i32) struct { sin: i32, cos: i32 } {
    // The source reads a 4096-entry (sin,cos) table.  The port uses the same
    // mathematical values and rounds to the table's integer scale; the focused
    // gate checks the resulting projection against the source-table reference.
    var tick = @mod(angle, 4096);
    if (tick < 0) tick += 4096;
    const radians = @as(f64, @floatFromInt(tick)) * (2.0 * std.math.pi / 4096.0);
    const sine: i32 = @intFromFloat(@round(4096.0 * @sin(radians)));
    const cosine: i32 = @intFromFloat(@round(4096.0 * @cos(radians)));
    return .{ .sin = sine, .cos = cosine };
}

/// Literal three-angle builder (source 0x8014FCB4).  Every product is shifted
/// by 12 exactly as the MIPS `sra` does, so the intermediate truncation is not
/// folded away.
pub fn rotationMatrix(angles: model.Vec3) [9]i32 {
    const a = sinCos(angles.x);
    const b = sinCos(angles.y);
    const c = sinCos(angles.z);
    const t3: i64 = a.sin;
    const t0: i64 = a.cos;
    const t6: i64 = b.sin;
    const t1: i64 = b.cos;
    const t4: i64 = -t6;
    const t5: i64 = c.sin;
    const t2: i64 = c.cos;
    var m: [9]i32 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    m[2] = @intCast(t6);
    m[5] = @intCast((-(t1 * t3)) >> 12);
    m[8] = @intCast((t1 * t0) >> 12);
    m[0] = @intCast((t2 * t1) >> 12);
    m[1] = @intCast((-(t5 * t1)) >> 12);
    const t8 = (t2 * t4) >> 12;
    m[3] = @intCast(((t5 * t0) >> 12) - ((t8 * t3) >> 12));
    m[6] = @intCast(((t5 * t3) >> 12) + ((t8 * t0) >> 12));
    const t8b = (t5 * t4) >> 12;
    m[4] = @intCast(((t2 * t0) >> 12) + ((t8b * t3) >> 12));
    m[7] = @intCast(((t2 * t3) >> 12) - ((t8b * t0) >> 12));
    return m;
}

pub fn scaleMatrix(matrix: [9]i32, scale: model.Vec3) [9]i32 {
    const d = [3]i64{ scale.x, scale.y, scale.z };
    var out: [9]i32 = undefined;
    for (0..9) |i| {
        out[i] = @intCast((@as(i64, matrix[i]) * d[i % 3]) >> 12);
    }
    return out;
}

fn projectCentered(block: model.Block, world_units: model.Vec3, focal_length_px: i32) !struct { point: Vec2f, depth: f32 } {
    const matrix = scaleMatrix(rotationMatrix(block.angles), block.scale);
    const translation = [3]i32{ block.translation.x, block.translation.y, block.translation.z };
    const world = [3]i32{ world_units.x, world_units.y, world_units.z };
    var camera_space: [3]i64 = undefined;
    for (0..3) |i| {
        var acc: i64 = @as(i64, translation[i]) << q12.fraction_bits;
        for (0..3) |j| acc += @as(i64, matrix[i * 3 + j]) * world[j];
        camera_space[i] = q12.floorToInt(acc);
    }
    if (camera_space[2] < 2) return error.NonPositiveDepth;
    const depth: f32 = @floatFromInt(camera_space[2]);
    return .{
        .point = .{
            .x = @as(f32, @floatFromInt(focal_length_px)) * @as(f32, @floatFromInt(camera_space[0])) / depth,
            .y = @as(f32, @floatFromInt(focal_length_px)) * @as(f32, @floatFromInt(camera_space[1])) / depth,
        },
        .depth = depth,
    };
}

/// Scene scroll from the source: project(origin) - project(position).
pub fn sceneScroll(block: model.Block, focal_length_px: i32) !Vec2f {
    const origin = try projectCentered(block, .{ .x = 0, .y = 0, .z = 0 }, focal_length_px);
    const position = try projectCentered(block, block.position, focal_length_px);
    return .{ .x = origin.point.x - position.point.x, .y = origin.point.y - position.point.y };
}

pub fn project(
    projection: Perspective,
    block: model.Block,
    scroll: Vec2f,
    world_q12: model.Vec3,
) !ScreenPoint {
    const world = floorQ12Vector(.{ world_q12.x, world_q12.y, world_q12.z });
    const centred = try projectCentered(block, world, projection.focal_length_px);
    return .{
        .x = @as(f32, @floatFromInt(projection.center_x_px)) + centred.point.x + scroll.x,
        .y = @as(f32, @floatFromInt(projection.center_y_px)) + centred.point.y + scroll.y,
        .depth = centred.depth,
    };
}

pub fn projectNoScroll(projection: Perspective, block: model.Block, world_q12: model.Vec3) !ScreenPoint {
    return project(projection, block, .{ .x = 0, .y = 0 }, world_q12);
}

/// camera_setup: copy a preset and an explicit frame count into timers and
/// truncating deltas.  A zero frame count would trap in the source and is an
/// error here, never a silent snap.
pub fn interpolation(target: [12]i32, live: [12]i32, frames: u16) !Interpolation {
    if (frames == 0) return error.InvalidFrameCount;
    var deltas: [12]i32 = undefined;
    for (0..12) |i| {
        const difference: i64 = @as(i64, target[i]) - @as(i64, live[i]);
        deltas[i] = @intCast(@divTrunc(difference, @as(i64, frames)));
    }
    return .{ .timers = .{ frames, frames, frames, frames }, .deltas = deltas };
}

/// One source frame.  Returns true when every timer is zero and the live block
/// is the target block.  Timer-zero groups snap to the target; while a timer is
/// positive it decrements and adds the delta (the source's -1 arm is defensive
/// and is reproduced rather than simplified).
pub fn advance(
    live: *[12]i32,
    target: [12]i32,
    timers: *[4]i32,
    deltas: [12]i32,
) !bool {
    for (0..4) |group| {
        if (timers[group] < 0) return error.InvalidTimer;
        const base = group * 3;
        if (timers[group] == 0) {
            for (0..3) |k| live[base + k] = target[base + k];
        } else {
            timers[group] -= 1;
            if (timers[group] != -1) {
                for (0..3) |k| live[base + k] += deltas[base + k];
            }
        }
    }
    if (!std.mem.eql(i32, live, &target)) return false;
    for (timers) |timer| if (timer != 0) return false;
    return true;
}

pub fn eqlBlock(live: [12]i32, target: [12]i32) bool {
    return std.mem.eql(i32, &live, &target);
}

pub fn actorTrackTarget(
    base_raw: [12]i32,
    template: model.ActorTrackDef,
    actor_raw: model.Vec3,
) [12]i32 {
    // 0x800F8904 copies actor X/Y into the position, installs Z from the
    // template, and does NOT write words 6-8 (the translation is inherited).
    var raw = template.template_raw;
    raw[0] = actor_raw.x;
    raw[1] = actor_raw.y;
    raw[6] = base_raw[6];
    raw[7] = base_raw[7];
    raw[8] = base_raw[8];
    return raw;
}
