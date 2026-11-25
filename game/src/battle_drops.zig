//! Drops of Kindness callback choreography. Art is attached only by a review package.
const std = @import("std");
const camera = @import("battle_camera");
pub const Point = struct { x: f32, y: f32 };
pub const Entry = struct { x: i32, y: i32, w: i32, h: i32, dx: i32, dy: i32 };
pub const Art = struct {
    schema: []const u8,
    entries: [4]Entry,
    pub fn validate(self: Art, width: i32, height: i32) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-drops-art/1")) return error.InvalidDropsArt;
        for (self.entries, 0..) |entry, i| {
            if (entry.w != (if (i == 0) @as(i32, 64) else 16) or entry.h != (if (i == 0) @as(i32, 64) else 32) or entry.dx != -@divTrunc(entry.w, 2) or entry.dy != -@divTrunc(entry.h, 2) or entry.x < 0 or entry.y < 0 or entry.x > width - entry.w or entry.y > height - entry.h) return error.InvalidDropsArt;
        }
    }
};
pub const Parameters = struct { caster_visible: bool, targets_visible: bool, caster_scale: i32, intensity: u8, spread: i32, column_top: i32, wash: [3]u8, orbit_updates: i32, healed: bool };
pub fn parameters(update: u16) Parameters {
    const n: i32 = @min(update, 306);
    const a = @min(n, 64);
    const b = std.math.clamp(n - 64, 0, 32);
    const c = std.math.clamp(n - 96, 0, 90);
    const d = std.math.clamp(n - 186, 0, 60);
    const e = std.math.clamp(n - 246, 0, 60);
    return .{ .caster_visible = n > 0 and n < 96, .targets_visible = n > 96 and n < 306, .caster_scale = 1 + 64 * a + 128 * b, .intensity = @truncate(@as(u32, @bitCast((8192 * a - 16384 * b + 5779 * c - 8669 * e) >> 12))), .spread = (1 + 186413 * c - 279620 * e) >> 12, .column_top = -5 - 3 * d, .wash = .{ 0, @intCast(@max(0, (2048 * a - 2184 * e) >> 12)), @intCast(@max(0, (4096 * a - 4369 * e) >> 12)) }, .orbit_updates = @max(n - 96, 0), .healed = n == 306 };
}
pub const initial_camera = camera.Block{ .position = .{ 0, 0, 0 }, .angles = .{ -768, 0, 608 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } };
pub fn cameraAt(update: u16) camera.Block {
    var result = initial_camera;
    const target = camera.attack_party;
    const n: i32 = @min(update, 60);
    inline for (.{ "position", "angles", "c", "d" }) |field| {
        for (0..3) |i| {
            const a = @field(initial_camera, field)[i] << 12;
            const b = @field(target, field)[i] << 12;
            @field(result, field)[i] = (if (n == 60) b else a + @divTrunc(b - a, 60) * n) >> 12;
        }
    }
    return result;
}
pub const rawProject = camera.rawProject;
pub fn project(block: camera.Block, p: [3]i32) camera.Screen {
    return camera.projectScene(block, p, .{}).?;
}
fn transform(p: [3]i32, angle: i32, scale: [3]i32, translation: [3]i32) [3]i32 {
    const block = camera.Block{ .position = .{ 0, 0, 0 }, .angles = .{ 0, 0, angle }, .c = translation, .d = scale };
    const r = camera.scaledRot(block);
    var out: [3]i32 = undefined;
    for (0..3) |i| {
        var sum: i64 = @as(i64, translation[i]) << 12;
        for (0..3) |j| sum += @as(i64, r[3 * i + j]) * p[j];
        const short: i16 = @bitCast(@as(u16, @truncate(@as(u64, @bitCast(sum >> 12)))));
        out[i] = short;
    }
    return out;
}
pub const Command = struct { vertices: [4]Point, count: u8 = 4, colors: [4][3]u8 = @splat(.{ 0, 0, 0 }), texture: ?u8 = null, intensity: u8 = 128, depth: i32 };
pub const Frame = struct {
    commands: [71]Command = undefined,
    count: usize = 0,
    wash: [3]u8,
    fn append(self: *Frame, command: Command) void {
        self.commands[self.count] = command;
        self.count += 1;
    }
};
fn point(p: camera.Screen) Point {
    return .{ .x = p.x, .y = p.y };
}
fn sprite(frame: *Frame, art: Art, texture: u8, anchor: camera.Screen, scale: i32, intensity: u8) void {
    const entry = art.entries[texture];
    const corners = [4][3]i32{ .{ entry.dx, entry.dy, 0 }, .{ entry.dx + entry.w, entry.dy, 0 }, .{ entry.dx, entry.dy + entry.h, 0 }, .{ entry.dx + entry.w, entry.dy + entry.h, 0 } };
    var command = Command{ .vertices = undefined, .texture = texture, .intensity = intensity, .depth = std.math.clamp(@as(i32, @intFromFloat(anchor.depth)) >> 2, 5, 379) };
    for (corners, 0..) |corner, i| {
        const v = transform(corner, 1, @splat(scale), .{ 0, 0, 1024 });
        command.vertices[i] = .{ .x = anchor.x + @as(f32, @floatFromInt(v[0])), .y = anchor.y + @as(f32, @floatFromInt(v[1])) };
    }
    frame.append(command);
}
pub fn frameAt(art: Art, update: u16, draws: [18]u15, caster: [3]i32, target: [3]i32) Frame {
    return frameWithCamera(art, update, draws, caster, target, cameraAt(update));
}

pub fn frameWithCamera(art: Art, update: u16, draws: [18]u15, caster: [3]i32, target: [3]i32, block: camera.Block) Frame {
    const p = parameters(update);
    const scene_scale = @divTrunc(block.d[0] << 10, block.c[2]);
    var frame = Frame{ .wash = if (update < 306) p.wash else .{ 0, 0, 0 } };
    if (p.caster_visible) sprite(&frame, art, 0, project(block, .{ caster[0], caster[1], caster[2] - 70 }), @divTrunc(scene_scale * p.caster_scale, 4096), p.intensity);
    if (p.targets_visible) for (0..6) |i| {
        const local = [3]i32{ 20, 0, -@as(i32, draws[3 * i + 1] % 100) };
        const position = transform(local, @as(i32, draws[3 * i + 2] % 4096) + 32 * p.orbit_updates, .{ p.spread, p.spread, 4096 }, target);
        sprite(&frame, art, @intCast(1 + @mod(@divTrunc(p.orbit_updates, 5), 3)), project(block, position), @divTrunc(scene_scale * (2048 + @as(i32, draws[3 * i] % 4096)), 4096), p.intensity);
    };
    if (update > 0 and update < 306) {
        var inner: [32]camera.Screen = undefined;
        var outer: [32]camera.Screen = undefined;
        for (0..32) |i| {
            inner[i] = project(block, transform(.{ 30, 0, p.column_top }, -128 * @as(i32, @intCast(i)), .{ p.spread, p.spread, 4096 }, target));
            outer[i] = project(block, transform(.{ 30, 0, 0 }, -128 * @as(i32, @intCast(i)), .{ p.spread, p.spread, 4096 }, target));
        }
        for (0..32) |i| {
            const j = (i + 1) % 32;
            frame.append(.{ .vertices = .{ point(project(block, target)), point(outer[i]), point(outer[j]), .{ .x = 0, .y = 0 } }, .count = 3, .colors = .{ .{ 0, 0, 0 }, .{ 127, 127, 127 }, .{ 127, 127, 127 }, .{ 0, 0, 0 } }, .depth = 379 });
            frame.append(.{ .vertices = .{ point(inner[i]), point(inner[j]), point(outer[i]), point(outer[j]) }, .colors = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 80 }, .{ 0, 0, 80 } }, .depth = std.math.clamp(@as(i32, @intFromFloat((inner[i].depth + inner[j].depth + outer[i].depth + outer[j].depth) / 16)), 1, 509) });
        }
    }
    return frame;
}

pub const Instance = struct { draws: [18]u15, caster: [3]i32, target: [3]i32 };
