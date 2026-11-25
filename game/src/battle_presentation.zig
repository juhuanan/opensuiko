const std = @import("std");
pub const Vec3 = struct { x: f32, y: f32, z: f32 };
pub const ScreenPoint = struct { x: f32, y: f32, depth: f32 };
pub const Camera = struct { transform: [3][4]f32, focal_length: f32, center_x: f32, center_y: f32 };
pub const Leap = struct { ticks: u16, offset: Vec3, velocity: Vec3, acceleration_step: f32 = 0 };
pub const Stage = struct { start: u16, home: bool, leap: Leap };
pub const Motion = struct { ready_tick: ?u16 = null, stages: []const Stage = &.{}, approach_start: u16, approach: Leap, impact_tick: u16, return_start: u16, retreat: Leap, duration: u16 };
pub const Shadow = struct { point: ScreenPoint, radius_x: f32, radius_y: f32 };

pub fn project(camera: Camera, p: Vec3) ScreenPoint {
    var view: [3]f32 = undefined;
    for (camera.transform, 0..) |row, i| view[i] = row[0] * p.x + row[1] * p.y + row[2] * p.z + row[3];
    const depth = @max(1, view[2]);
    return .{ .x = std.math.clamp(camera.center_x + camera.focal_length * view[0] / depth, -32768, 32768), .y = std.math.clamp(camera.center_y + camera.focal_length * view[1] / depth, -32768, 32768), .depth = depth };
}

pub fn contactShadow(camera: Camera, home: Vec3, actor: Vec3, foot_offset_y: i16, sprite_scale: f32) Shadow {
    var point = project(camera, .{ .x = actor.x, .y = actor.y, .z = home.z });
    const scale = std.math.clamp(sprite_scale * project(camera, home).depth / point.depth, 0.25, 4);
    point.y += @as(f32, @floatFromInt(foot_offset_y)) * scale;
    // shortcut: flat party ellipses approximate the reference; original shadow geometry is not exported.
    return .{ .point = point, .radius_x = 24 * scale, .radius_y = 7.2 * scale };
}

// Constant acceleration reaches the destination after the source-defined tick count.
pub fn leap(start: Vec3, destination: Vec3, motion: Leap, tick: u16) Vec3 {
    if (tick >= motion.ticks) return destination;
    const t: f32 = @floatFromInt(tick);
    const duration: f32 = @floatFromInt(motion.ticks);
    const denominator = duration * (duration - 1) / 2;
    var acceleration = Vec3{ .x = (destination.x - start.x - motion.velocity.x * duration) / denominator, .y = (destination.y - start.y - motion.velocity.y * duration) / denominator, .z = (destination.z - start.z - motion.velocity.z * duration) / denominator };
    if (motion.acceleration_step > 0) {
        acceleration.x = @trunc(acceleration.x / motion.acceleration_step) * motion.acceleration_step;
        acceleration.y = @trunc(acceleration.y / motion.acceleration_step) * motion.acceleration_step;
        acceleration.z = @trunc(acceleration.z / motion.acceleration_step) * motion.acceleration_step;
    }
    const steps = t * (t - 1) / 2;
    return .{ .x = start.x + motion.velocity.x * t + acceleration.x * steps, .y = start.y + motion.velocity.y * t + acceleration.y * steps, .z = start.z + motion.velocity.z * t + acceleration.z * steps };
}

pub fn offset(p: Vec3, delta: Vec3) Vec3 {
    return .{ .x = p.x + delta.x, .y = p.y + delta.y, .z = p.z + delta.z };
}

pub fn fadeAlpha(elapsed: u16) u8 {
    return @intCast((32 - @as(u32, @min(32, elapsed))) * 255 / 32);
}

pub fn actorPosition(home: Vec3, target: Vec3, motion: Motion, tick: u16) Vec3 {
    return actorPositionFrom(home, home, target, motion, tick);
}

pub fn actorPositionFrom(start: Vec3, home: Vec3, target: Vec3, motion: Motion, tick: u16) Vec3 {
    if (tick < motion.approach_start) return start;
    var contact = offset(target, motion.approach.offset);
    if (motion.stages.len > 0) {
        var from = start;
        for (motion.stages) |stage| {
            contact = offset(target, stage.leap.offset);
            if (tick < stage.start) return from;
            if (tick < stage.start + stage.leap.ticks) return leap(from, contact, stage.leap, tick - stage.start);
            from = contact;
        }
        if (tick < motion.return_start) return from;
        return leap(from, home, motion.retreat, tick - motion.return_start);
    }
    if (tick < motion.return_start) return leap(start, contact, motion.approach, tick - motion.approach_start);
    return leap(contact, home, motion.retreat, tick - motion.return_start);
}
