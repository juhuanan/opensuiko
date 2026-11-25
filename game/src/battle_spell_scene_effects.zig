const std = @import("std");
const camera = @import("battle_camera");
const geometry = @import("battle_drops.zig");
const types = @import("battle_spell_scene_types.zig");
const packet_mod = @import("battle_spell_scene_packet.zig");
const instance_mod = @import("battle_spell_scene_instance.zig");
const scene = @import("battle_spell_scene.zig");

const Point = types.Point;
const Reaction = types.Reaction;
const HurtPose = types.HurtPose;
const ReactionSample = types.ReactionSample;
const BackgroundWarp = types.BackgroundWarp;
const ActorTransform = types.ActorTransform;
const Program = types.Program;
const Packet = packet_mod.Packet;
const Target = instance_mod.Target;
const Instance = instance_mod.Instance;
const Command = scene.Command;
const Frame = scene.Frame;

pub fn reactionAt(packet: *const Packet, instance: *const Instance, update: u16, actor: []const u8) ?ReactionSample {
    const program = instance.sceneProgram(packet);
    return reactionSample(packet, instance, update, actor, program.reaction);
}

pub fn partyReactionAt(packet: *const Packet, instance: *const Instance, update: u16, actor: []const u8) ?ReactionSample {
    return reactionSample(packet, instance, update, actor, instance.sceneProgram(packet).party_reaction);
}

fn reactionSample(packet: *const Packet, instance: *const Instance, update: u16, actor: []const u8, optional_reaction: ?Reaction) ?ReactionSample {
    const program = instance.sceneProgram(packet);
    const reaction = optional_reaction orelse return null;
    if (update < reaction.start or update >= program.duration or update - reaction.start >= reaction.offsets.len) return null;
    if (reaction.active_samples.len != 0 and !reaction.active_samples[update - reaction.start]) return null;
    var result = ReactionSample{ .animation = reaction.animation, .elapsed = update - reaction.start, .offset = reaction.offsets[update - reaction.start] };
    if (result.elapsed < reaction.tints.len) result.color = reaction.tints[result.elapsed];
    for (packet.hurt_poses) |pose| if (std.mem.eql(u8, actor, pose.id)) {
        result.entry = pose.entry;
        if (result.elapsed < reaction.flash_frames.len) if (reaction.flash_frames[result.elapsed]) |variant| {
            if (variant == 3) {
                if ((@as(u32, update) + instance.flicker_phase) % 2 == 0) if (pose.white_entry) |entry| {
                    result.entry = entry;
                };
            } else if (variant >= 4) {
                if (pose.shock_entries) |entries| result.entry = entries[variant - 4];
            } else if (pose.flash_entries) |entries| result.entry = entries[variant];
        };
        break;
    };
    return result;
}

pub fn knockoutStart(program: Program) u16 {
    return @max(program.impact, if (program.reaction) |reaction| reaction.start + (reaction.release orelse @as(u16, @intCast(reaction.offsets.len))) else 0);
}

pub fn knockoutAt(pose: HurtPose, program: Program, elapsed: u16) ?ReactionSample {
    const ko = pose.knockout orelse return null;
    var offset: [2]i16 = .{ 0, 0 };
    var initial: ?u16 = null;
    var animation: u8 = 0;
    if (program.reaction) |reaction| if (knockoutStart(program) < reaction.start + reaction.offsets.len) {
        offset = reaction.offsets[knockoutStart(program) - reaction.start];
        initial = pose.entry;
        animation = 1;
    };
    // Visibility clears two updates before callback restoration and lock release finish.
    return .{ .elapsed = elapsed, .offset = offset, .animation = if (elapsed == 0) animation else 3, .entry = if (elapsed == 0) initial else ko.entry, .visible = elapsed < ko.duration - 2, .tint = @intCast(@max(0, 128 - 2 * @as(i32, elapsed -| 2))), .blend = if (elapsed < 2) .@"opaque" else .subtractive };
}

pub fn knockoutAfterHurt(pose: HurtPose, elapsed: u16) ?ReactionSample {
    const ko = pose.knockout orelse return null;
    return .{ .elapsed = elapsed, .offset = .{ 0, 0 }, .animation = 3, .entry = ko.entry, .visible = elapsed < ko.duration - 2, .tint = @intCast(@max(0, 128 - 2 * @as(i32, elapsed -| 2))), .blend = if (elapsed < 2) .@"opaque" else .subtractive };
}

/// Copies mutable effect pixels; no returned slice aliases a copied battle state.
pub fn erosionPixels(packet: *const Packet, instance: *const Instance, entry: u16, out: *[4096][4]u8) bool {
    const erosion = instance.sceneProgram(packet).erosion orelse return false;
    if (entry != erosion.entry) return false;
    @memset(out, .{ 0, 0, 0, 0 });
    for (erosion.view_cells, erosion.view_upper, erosion.colors, 0..) |cell, upper, color, i| {
        const width: usize = @intCast(packet.entries[entry].w);
        const pixel = (i / width) * 64 + i % width;
        out[pixel] = color;
        const level = instance.coverage[cell];
        if (if (upper) level != 2 else level == 0 or !erosion.lower_present[cell]) out[pixel][3] = 0;
    }
    return true;
}

/// Imported source and destination vertices sample the port's own ground pass.
pub fn appendBackgroundWarp(frame: *Frame, warp: BackgroundWarp, block: camera.Block, update: u16) void {
    appendBackgroundWarpAt(frame, warp, block, update, @splat(0));
}

pub fn appendBackgroundWarpAt(frame: *Frame, warp: BackgroundWarp, block: camera.Block, update: u16, translation: [3]i32) void {
    if (update >= warp.samples.len) return;
    const mesh = warp.samples[update] orelse return;
    for (warp.faces) |face| {
        var command = Command{ .vertices = undefined, .count = face.count, .background_uv = @as([4]Point, @splat(.{ .x = 0, .y = 0 })), .depth = warp.depth, .blend = .@"opaque", .tint = @splat(127) };
        var x: [4]i32 = @splat(0);
        var minimum: i32 = std.math.maxInt(i32);
        for (face.indices[0..face.count], 0..) |index, i| {
            const src = mesh.source[index];
            const dst = mesh.destination[index];
            var source: [3]i32 = undefined;
            var destination: [3]i32 = undefined;
            for (0..3) |axis| {
                source[axis] = @as(i16, @truncate(@as(i32, src[axis]) + translation[axis]));
                destination[axis] = @as(i16, @truncate(@as(i32, dst[axis]) + translation[axis]));
            }
            const uv = geometry.project(block, source);
            const projected = geometry.project(block, destination);
            x[i] = @intFromFloat(uv.x);
            minimum = @min(minimum, x[i]);
            command.background_uv.?[i].y = @floatFromInt(@mod(@as(i32, @intFromFloat(uv.y)), 256));
            command.vertices[i] = .{ .x = projected.x, .y = projected.y };
        }
        const tile = @divTrunc(minimum, 64) * 64;
        for (0..face.count) |i| command.background_uv.?[i].x = @floatFromInt(tile + @mod(x[i] - tile, 256));
        frame.append(command);
    }
}

pub fn groundDepth(projected_z: i32) u16 {
    return @intCast(std.math.clamp(380 + (std.math.clamp(projected_z, 0, 65535) >> 2), 380, 509));
}

pub fn backgroundCaptureMinimum(program: Program, update: u16) ?u16 {
    for (program.background_warps) |warp| if (update < warp.samples.len and warp.samples[update] != null) return warp.depth + 2;
    return null;
}

pub fn actorTransform(program: Program, target: Target, update: u16) !?ActorTransform {
    const motion = program.actor_motion orelse return null;
    if (!target.movable or update < motion.start) return null;
    if (update > program.duration or target.size_base < 0 or target.size_base > 65536) return error.InvalidSpellTargets;
    var destination: [3]i32 = undefined;
    for (motion.destination, 0..) |value, i| destination[i] = value * 4096;
    const returning = update >= motion.returning;
    const elapsed = @min(@as(u32, update) - (if (returning) motion.returning else motion.start) + 1, motion.updates);
    const velocity = if (returning) motion.return_velocity else motion.velocity;
    var start = if (returning) target.return_origin orelse destination else target.motion_origin orelse blk: {
        var result: [3]i32 = undefined;
        for (target.position, 0..) |value, i| {
            if (@abs(value) > 32767) return error.InvalidSpellTargets;
            result[i] = value * 4096;
        }
        break :blk result;
    };
    if (returning) for (target.home orelse target.position, 0..) |value, i| {
        if (@abs(value) > 32767) return error.InvalidSpellTargets;
        destination[i] = value * 4096;
    };
    const steps: i64 = @divTrunc(@as(i64, motion.updates) * (motion.updates - 1), 2);
    for (0..3) |i| {
        const acceleration = @divTrunc(@as(i64, destination[i]) - start[i] - @as(i64, velocity[i]) * motion.updates, steps);
        const position = if (elapsed == motion.updates) destination[i] else @as(i64, start[i]) + @as(i64, velocity[i]) * elapsed + acceleration * @as(i64, @intCast(elapsed * (elapsed - 1) / 2));
        start[i] = std.math.cast(i32, position) orelse return error.InvalidSpellTargets;
    }
    const size = target.size_base + @as(i32, motion.size_delta[update]);
    if (size < 0 or size > 65536) return error.InvalidSpellTargets;
    return .{ .position = start, .size = size };
}
