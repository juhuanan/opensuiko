const std = @import("std");
const camera = @import("battle_camera");
const geometry = @import("battle_drops.zig");
const types = @import("battle_spell_scene_types.zig");
const packet_mod = @import("battle_spell_scene_packet.zig");
const instance_mod = @import("battle_spell_scene_instance.zig");
const effects_mod = @import("battle_spell_scene_effects.zig");

pub const Blend = types.Blend;
pub const Anchor = types.Anchor;
pub const Point = types.Point;
pub const Entry = types.Entry;
pub const Sample = types.Sample;
pub const Variation = types.Variation;
pub const Flight = types.Flight;
pub const Object = types.Object;
pub const ColumnShape = types.ColumnShape;
pub const Mesh = types.Mesh;
pub const CameraEvent = types.CameraEvent;
pub const PulseSpawn = types.PulseSpawn;
pub const Emitter = types.Emitter;
pub const Reaction = types.Reaction;
pub const Knockout = types.Knockout;
pub const HurtPose = types.HurtPose;
pub const IdleFlashFrame = types.IdleFlashFrame;
pub const UniteImpact = types.UniteImpact;
pub const StatusKind = types.StatusKind;
pub const StatusIcon = types.StatusIcon;
pub const StatusAnchors = types.StatusAnchors;
pub const UniteMotion = types.UniteMotion;
pub const UniteImpactSpawn = types.UniteImpactSpawn;
pub const UniteStatusAttempt = types.UniteStatusAttempt;
pub const UniteSignal = types.UniteSignal;
pub const UniteReaction = types.UniteReaction;
pub const ReactionSample = types.ReactionSample;
pub const unitePosition = types.unitePosition;
pub const uniteReactionAt = types.uniteReactionAt;
pub const ScreenSample = types.ScreenSample;
pub const ScreenLayer = types.ScreenLayer;
pub const ScreenWash = types.ScreenWash;
pub const ScaleNoise = types.ScaleNoise;
pub const Erosion = types.Erosion;
pub const WarpFace = types.WarpFace;
pub const WarpGeometry = types.WarpGeometry;
pub const BackgroundWarp = types.BackgroundWarp;
pub const ActorMotion = types.ActorMotion;
pub const ActorTransform = types.ActorTransform;
pub const Program = types.Program;
pub const Spell = types.Spell;
pub const max_file_size = types.max_file_size;
pub const Packet = packet_mod.Packet;
pub const load = packet_mod.load;
pub const parseSchemaVersion = packet_mod.parseSchemaVersion;
pub const transition = instance_mod.transition;
pub const cameraAt = instance_mod.cameraAt;
pub const TrailPoint = instance_mod.TrailPoint;
pub const Particle = instance_mod.Particle;
pub const Target = instance_mod.Target;
pub const Instance = instance_mod.Instance;

pub const Command = struct {
    background_uv: ?[4]Point = null,
    vertices: [4]Point,
    count: u8 = 4,
    colors: [4][3]u8 = @splat(.{ 0, 0, 0 }),
    texture: ?u16 = null,
    tint: [3]u8 = @splat(128),
    opacity: u8 = 255,
    blend: Blend = .additive,
    depth: i32,

    pub fn drawsInPass(self: Command, capture_minimum: ?u16) bool {
        const minimum = capture_minimum orelse return true;
        // A warp cannot sample the render target while it is being written.
        return self.background_uv == null and self.depth >= minimum;
    }
};
pub const Frame = struct {
    pub const capacity = 512 + 6 * 8 + 6 * 18 + 6 * 32;
    commands: [capacity]Command = undefined,
    count: usize = 0,
    wash: [3]u8,
    wash_blend: Blend,
    pub fn append(self: *Frame, command: Command) void {
        std.debug.assert(self.count < self.commands.len);
        self.commands[self.count] = command;
        self.count += 1;
    }
};
fn origin(instance: Instance, anchor: Anchor) [3]i32 {
    return switch (anchor) {
        .caster => instance.caster,
        .target, .each_target => instance.target,
        .world, .party_member, .screen => .{ 0, 0, 0 },
        .target_lane => .{ 120, instance.target[1], 0 },
    };
}
fn variationValue(term: ?Variation, instance: *const Instance) i32 {
    const v = term orelse return 0;
    return v.bias + @as(i32, instance.draws[v.draw] % v.modulus) * v.multiplier;
}
pub fn vectorTransform(p: [3]i32, angles: [3]i32, scale: [3]i32, translation: [3]i32) [3]i32 {
    const r = camera.scaledRot(.{ .focus = .{ 0, 0, 0 }, .angles = angles, .scale = scale, .translation = translation });
    var result: [3]i32 = undefined;
    for (0..3) |i| {
        var sum: i64 = @as(i64, translation[i]) << 12;
        for (0..3) |j| sum += @as(i64, r[3 * i + j]) * p[j];
        result[i] = @as(i16, @bitCast(@as(u16, @truncate(@as(u64, @bitCast(sum >> 12))))));
    }
    return result;
}
fn point(p: camera.Screen) Point {
    return .{ .x = p.x, .y = p.y };
}
pub fn sceneOffsetQuad(block: camera.Block, center: camera.Screen, offsets: [4][3]i16) struct { vertices: [4]Point, depth: i32 } {
    var vertices: [4]Point = undefined;
    for (offsets, 0..) |offset, i| {
        const projected = camera.rawProject(block, .{ offset[0], offset[1], offset[2] });
        vertices[i] = .{ .x = center.x + @as(f32, @floatFromInt(projected[0])), .y = center.y + @as(f32, @floatFromInt(projected[1])) };
    }
    return .{ .vertices = vertices, .depth = @intFromFloat(center.depth) };
}
pub fn instanceCameraAt(program: Program, instance: *const Instance, update: u16) camera.Block {
    return withLandingKick(program, instance, update, cameraAt(program, update, instance.initial_camera));
}
pub fn withCameraPulses(program: Program, instance: *const Instance, update: u16, base: camera.Block) camera.Block {
    var result = base;
    if (update < program.focus_samples.len) if (program.focus_samples[update]) |focus| {
        // Exported samples bake the impulse into the uninterrupted spell camera.
        const reference = instance_mod.baseCameraAt(program, update, instance.initial_camera);
        for (0..3) |axis| result.focus[axis] += focus[axis] - reference.focus[axis];
    };
    return withLandingKick(program, instance, update, result);
}
fn withLandingKick(program: Program, instance: *const Instance, update: u16, base: camera.Block) camera.Block {
    var result = base;
    if (update != 0 and instance.last_landing == update and instance.last_landing_emitter < program.emitterCount()) {
        const emitter = program.emitterAt(instance.last_landing_emitter);
        result.focus[2] += emitter.focus_kick;
    }
    return result;
}
pub fn frameAt(packet: *const Packet, instance: *const Instance, update: u16) Frame {
    const program = instance.sceneProgram(packet);
    const block = instanceCameraAt(program, instance, update);
    return frameWithCamera(packet, instance, update, block);
}
pub fn frameWithCamera(packet: *const Packet, instance: *const Instance, update: u16, block: camera.Block) Frame {
    const program = instance.sceneProgram(packet);
    const scene_scale = @divTrunc(block.scale[0] << 10, block.translation[2]);
    var frame = Frame{ .wash = program.wash[@min(update, program.wash.len - 1)], .wash_blend = program.wash_blend };
    for (program.objects) |object| {
        const object_emitter = if (object.particle_index) |index| program.emitterForParticle(index) else null;
        const animated_sprite = object.particle_index != null and (object_emitter.?.kind == .spherical_sprites or object_emitter.?.kind == .seeded_spheres or object_emitter.?.kind == .cycling_sprites or object_emitter.?.kind == .orbiting_sprites or object_emitter.?.kind == .drifting_sprites);
        const falling = object.particle_index != null and object_emitter.?.kind == .falling_lines;
        const lightning = object.particle_index != null and (object_emitter.?.kind == .lightning_bolts or object_emitter.?.kind == .scheduled_pulses or object_emitter.?.kind == .falling_trails or object_emitter.?.kind == .bouncing_sprites or object_emitter.?.kind == .ballistic_sprites);
        if (object.particle_index) |index| {
            const particle = instance.particles[index];
            const visible = if (object.trail_index) |trail| particle.history[trail].visible else if (lightning) switch (object.particle_part) {
                .primary => particle.active,
                .spark => particle.splash_active,
                .pulse => particle.pulse_life > 0,
            } else if (falling) particle.splash_active else particle.active;
            if (!visible or update >= object_emitter.?.stop) continue;
        }
        if (object.anchor == .party_member and object.member_index >= instance.party_count) continue;
        if (update < object.start) continue;
        const age = if (lightning) switch (object.particle_part) {
            .primary => instance.particles[object.particle_index.?].age,
            .spark => instance.particles[object.particle_index.?].splash_age,
            .pulse => 0,
        } else if (animated_sprite) instance.particles[object.particle_index.?].age else if (falling) instance.particles[object.particle_index.?].splash_age else update - object.start + @as(u16, if (object.start > 0) 1 else 0);
        const track = program.tracks[object.track];
        const sample_index = if (object.piece_track != null) update else age;
        if (sample_index >= track.len) continue;
        const sample = track[sample_index];
        if (!sample.visible) continue;
        const piece = (if (object.piece_track) |piece_track| (if (age < program.tracks[piece_track].len) program.tracks[piece_track][age].piece else null) else sample.piece) orelse continue;
        const copies: usize = if (object.anchor == .each_target) @max(instance.target_count, 1) else 1;
        for (0..copies) |copy| {
            var base = if (object.anchor == .party_member) instance.party[object.member_index].position else origin(instance.*, object.anchor);
            var center = if (program.reaction_center_switch and update < program.reaction.?.start) instance.target_idle_center else instance.target_center;
            if (object.anchor == .each_target and instance.target_count > 0) {
                base = instance.targets[copy].position;
                center = instance.targets[copy].center;
            }
            if (lightning and object_emitter.?.strike_at != 0) center = instance.particles[object.particle_index.?].center;
            if (object.origin_until == 0 or update < object.origin_until) for (0..3) |i| {
                base[i] += object.origin[i];
            };
            var local: [3]i32 = undefined;
            for (0..3) |i| local[i] = (sample.position[i] + (if (object.particle_index) |index| (if (falling or (lightning and object.particle_part != .primary)) instance.particles[index].splash_position[i] else (if (object.trail_index) |trail| instance.particles[index].history[trail].position[i] else instance.particles[index].head[i])) else object.position[i]) + if (i == 2) variationValue(object.random_z, instance) + (if (lightning and object.particle_part == .spark) instance.particles[object.particle_index.?].spark_height else 0) else 0) >> 12;
            if (object.flight) |flight| {
                const steps = @min(if (age >= flight.start) age - flight.start + 1 else 0, flight.updates);
                for (0..3) |axis| {
                    const delta = (@as(i64, instance.target[axis] - instance.caster[axis]) << 12) - sample.position[axis] - (if (axis == 2) @as(i64, instance.target_height) * flight.target_height_q12 else 0);
                    const value = (@as(i64, sample.position[axis]) + @divTrunc(delta, flight.updates) * steps) >> 12;
                    local[axis] = @as(i16, @bitCast(@as(u16, @truncate(@as(u64, @bitCast(value))))));
                }
            }
            var angles = sample.angles;
            angles[2] += variationValue(object.random_angle, instance);
            const world = vectorTransform(local, angles, instance.sampleScale(sample), base);
            var anchor = geometry.project(block, world);
            if (object.anchor == .screen) anchor = .{ .x = @floatFromInt(160 + world[0]), .y = @floatFromInt(120 + world[1]), .depth = @floatFromInt(@as(u32, object.screen_depth.?) * 4) };
            if (object.center_on_target) {
                anchor.x += @as(f32, @floatFromInt(center[0]));
                if (object.center_y) anchor.y += @as(f32, @floatFromInt(center[1]));
            }
            const size = @divTrunc(scene_scale * (if (object.particle_index != null and instance.particles[object.particle_index.?].size_override != 0) instance.particles[object.particle_index.?].size_override else ((if (lightning and object.particle_part == .pulse) instance.particles[object.particle_index.?].pulse_size else sample.size) + variationValue(object.random_size, instance))), 4096);
            var node_angles = sample.node_angles;
            node_angles[2] += variationValue(object.random_node_angle, instance);
            for (0..3) |axis| node_angles[axis] += variationValue(object.random_node_angles[axis], instance);
            if (object.particle_index != null and object_emitter.?.kind == .bouncing_sprites and object.particle_part == .primary) node_angles[2] += instance.particles[object.particle_index.?].node_rotation;
            if (lightning and object.particle_part == .spark) node_angles[1] += instance.particles[object.particle_index.?].spark_angle;
            const node = camera.Block{ .focus = .{ 0, 0, 0 }, .angles = node_angles, .scale = @splat(size), .translation = .{ 0, 0, 1024 } };
            for (packet.pieces[piece]) |entry_id| {
                const entry = packet.entries[entry_id];
                if (sample.quad_offsets) |offsets| {
                    const quad = sceneOffsetQuad(block, anchor, offsets);
                    frame.append(.{ .vertices = quad.vertices, .texture = entry_id, .tint = sample.tint, .blend = object.blend, .depth = std.math.clamp(@as(i32, @intFromFloat(anchor.depth)), 0, 65535) >> 2 });
                    continue;
                }
                const corners = [4][3]i32{ .{ entry.dx, entry.dy, 0 }, .{ entry.dx + entry.w, entry.dy, 0 }, .{ entry.dx, entry.dy + entry.h, 0 }, .{ entry.dx + entry.w, entry.dy + entry.h, 0 } };
                var command = Command{ .vertices = undefined, .texture = entry_id, .tint = sample.tint, .blend = object.blend, .depth = std.math.clamp(@as(i32, @intFromFloat(anchor.depth)) >> 2, 5, 379) };
                for (corners, 0..) |corner, i| {
                    const offset = geometry.rawProject(node, corner);
                    command.vertices[i] = .{ .x = anchor.x + @as(f32, @floatFromInt(offset[0])), .y = anchor.y + @as(f32, @floatFromInt(offset[1])) };
                }
                frame.append(command);
            }
        }
    }
    for (program.meshes) |mesh| {
        if (update < mesh.start or update >= mesh.stop) continue;
        const sample = program.tracks[mesh.track][update];
        if (!sample.visible) continue;
        var upper: [64]camera.Screen = undefined;
        var lower: [64]camera.Screen = undefined;
        var upper_end: [64]camera.Screen = undefined;
        var lower_end: [64]camera.Screen = undefined;
        var translation = origin(instance.*, mesh.anchor);
        for (0..3) |axis| translation[axis] += mesh.origin[axis];
        if (mesh.kind == .strip) {
            for (0..3) |axis| translation[axis] += @intCast((@as(i64, sample.position[axis]) + @as(i64, instance.target[axis] - instance.caster[axis]) * sample.target_weight[axis]) >> 12);
            const anchor = geometry.project(block, translation);
            const edges = mesh.strip_edges[if (mesh.strip_edges.len == 1) 0 else update];
            for (0..mesh.segments) |i| {
                const quad = sceneOffsetQuad(block, anchor, .{ edges[i][0], edges[i + 1][0], edges[i][1], edges[i + 1][1] });
                frame.append(.{ .vertices = quad.vertices, .colors = .{ sample.tint, sample.tint, mesh.inner, mesh.inner }, .depth = mesh.depth orelse std.math.clamp(@divTrunc(quad.depth, 4), 1, 509), .blend = mesh.blend });
            }
            continue;
        }
        const shape: ColumnShape = if (mesh.shape_samples.len != 0) mesh.shape_samples[update] else .{
            .radius = mesh.radius,
            .top_radius = mesh.top_radius orelse mesh.radius,
            .base_height = if (mesh.base_heights.len != 0) mesh.base_heights[update] else 0,
            .height = if (mesh.kind == .column) mesh.heights[update] else 0,
            .inner = mesh.inner,
            .outer = mesh.outer,
        };
        const segment_gap = if (mesh.segment_gaps.len != 0) mesh.segment_gaps[update] else mesh.segment_gap;
        const center = geometry.project(block, translation);
        for (0..mesh.segments) |i| {
            const angle: i32 = -@divTrunc(4096, @as(i32, mesh.segments)) * @as(i32, @intCast(i));
            if (mesh.kind == .band) {
                const sign: i32 = if (i < mesh.segments / 2) 1 else -1;
                var angles = sample.angles;
                angles[1] += sign * @as(i32, mesh.opening[update]);
                angles[2] += angle;
                lower[i] = geometry.project(block, vectorTransform(.{ 0, mesh.radius, 0 }, angles, instance.sampleScale(sample), translation));
                angles[1] += sign * @as(i32, mesh.spread[update]);
                upper[i] = geometry.project(block, vectorTransform(.{ 0, mesh.radius, 0 }, angles, instance.sampleScale(sample), translation));
            } else {
                var angles = mesh.angles;
                if (mesh.animated_angles) for (0..3) |axis| {
                    angles[axis] += sample.angles[axis];
                };
                angles[2] += angle;
                lower[i] = geometry.project(block, vectorTransform(.{ shape.radius, 0, shape.base_height }, angles, instance.sampleScale(sample), translation));
                if (mesh.kind == .column) upper[i] = geometry.project(block, vectorTransform(.{ shape.top_radius, 0, shape.height }, angles, instance.sampleScale(sample), translation));
                if (segment_gap != 0) {
                    angles[2] -= @divTrunc(4096, @as(i32, mesh.segments)) - segment_gap;
                    lower_end[i] = geometry.project(block, vectorTransform(.{ shape.radius, 0, shape.base_height }, angles, instance.sampleScale(sample), translation));
                    upper_end[i] = geometry.project(block, vectorTransform(.{ shape.top_radius, 0, shape.height }, angles, instance.sampleScale(sample), translation));
                }
            }
        }
        for (0..mesh.segments) |i| {
            const j = (i + 1) % mesh.segments;
            if (segment_gap != 0) {
                frame.append(.{ .vertices = .{ point(upper[i]), point(upper_end[i]), point(lower[i]), point(lower_end[i]) }, .colors = .{ shape.inner, shape.inner, shape.outer, shape.outer }, .depth = mesh.depth orelse std.math.clamp(@as(i32, @intFromFloat((upper[i].depth + upper_end[i].depth + lower[i].depth + lower_end[i].depth) / 16)), 1, 378), .blend = mesh.blend });
                continue;
            }
            if (mesh.kind == .fan) frame.append(.{ .vertices = .{ point(center), point(lower[i]), point(lower[j]), .{ .x = 0, .y = 0 } }, .count = 3, .colors = .{ mesh.inner, mesh.outer, mesh.outer, mesh.inner }, .depth = mesh.depth orelse 379, .blend = mesh.blend }) else frame.append(.{ .vertices = .{ point(upper[i]), point(upper[j]), point(lower[i]), point(lower[j]) }, .colors = .{ shape.inner, shape.inner, shape.outer, shape.outer }, .depth = mesh.depth orelse std.math.clamp(@as(i32, @intFromFloat(if (mesh.kind == .band) lower[i].depth / 4 else (upper[i].depth + upper[j].depth + lower[i].depth + lower[j].depth) / 16)), 1, 509), .blend = mesh.blend });
        }
    }
    for (program.screen_washes) |screen| {
        if (update >= screen.colors.len) continue;
        const color = screen.colors[update] orelse continue;
        frame.append(.{ .vertices = .{ .{ .x = 0, .y = 0 }, .{ .x = 320, .y = 0 }, .{ .x = 0, .y = 240 }, .{ .x = 320, .y = 240 } }, .colors = @splat(color), .depth = screen.depth, .blend = screen.blend });
    }
    for (0..program.emitterCount()) |emitter_index| {
        const emitter = program.emitterAt(emitter_index);
        if (emitter.kind == .inward_points and update >= emitter.start and update < emitter.stop) for (instance.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |particle| {
            if (!particle.active) continue;
            var position: [3]i32 = undefined;
            for (0..3) |axis| position[axis] = @as(i16, @truncate(emitter.origin[axis] + (particle.head[axis] >> 12)));
            const p = point(geometry.project(block, position));
            frame.append(.{ .vertices = .{ p, .{ .x = p.x + 1, .y = p.y }, .{ .x = p.x, .y = p.y + 1 }, .{ .x = p.x + 1, .y = p.y + 1 } }, .colors = @splat(emitter.color), .blend = .@"opaque", .depth = 0 });
        };
        if ((emitter.kind == .inward_lines or emitter.kind == .falling_lines or emitter.kind == .rising_lines) and update >= emitter.start and update < emitter.stop) for (instance.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |particle| {
            if (!particle.active) continue;
            var head: [3]i32 = undefined;
            var tail: [3]i32 = undefined;
            for (0..3) |i| {
                const base = if (emitter.kind == .falling_lines) emitter.origin[i] else instance.caster[i];
                head[i] = base + (particle.head[i] >> 12);
                tail[i] = base + (particle.tail[i] >> 12);
            }
            if (emitter.kind == .rising_lines) {
                var local_head: [3]i32 = undefined;
                var local_tail: [3]i32 = undefined;
                for (0..3) |axis| {
                    local_head[axis] = particle.head[axis] >> 12;
                    local_tail[axis] = particle.tail[axis] >> 12;
                }
                head = vectorTransform(local_head, @splat(0), particle.spawn_scale, instance.target);
                tail = vectorTransform(local_tail, @splat(0), particle.spawn_scale, instance.target);
            }
            if (emitter.model_track) |track| {
                const sample = program.tracks[track][update];
                const base = if (emitter.anchor == .world) emitter.origin else instance.caster;
                var local_head: [3]i32 = undefined;
                var local_tail: [3]i32 = undefined;
                for (0..3) |axis| {
                    local_head[axis] = particle.head[axis] >> 12;
                    local_tail[axis] = particle.tail[axis] >> 12;
                }
                head = vectorTransform(local_head, sample.angles, instance.sampleScale(sample), base);
                tail = vectorTransform(local_tail, sample.angles, instance.sampleScale(sample), base);
            }
            const a = geometry.project(block, head);
            const b = geometry.project(block, tail);
            frame.append(.{ .vertices = .{ point(a), point(b), .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 } }, .count = 2, .colors = @splat(emitter.color), .blend = if (emitter.kind == .falling_lines) .additive else .@"opaque", .depth = std.math.clamp(@as(i32, @intFromFloat(b.depth)) >> 2, 1, 509) });
        };
    }
    for (program.background_warps) |warp| effects_mod.appendBackgroundWarpAt(&frame, warp, block, update, origin(instance.*, warp.anchor));
    for (program.screen_layers) |layer| {
        if (update >= layer.samples.len) continue;
        const sample = layer.samples[update] orelse continue;
        for (0..layer.copies) |_| for (layer.entries, sample.vertices) |entry, quad| {
            var vertices: [4]Point = undefined;
            for (quad, 0..) |xy, i| vertices[i] = .{ .x = @floatFromInt(xy[0]), .y = @floatFromInt(xy[1]) };
            frame.append(.{ .vertices = vertices, .texture = entry, .tint = sample.rgb orelse @splat(sample.tint), .depth = 0, .blend = layer.blend });
        };
    }
    return frame;
}

pub const reactionAt = effects_mod.reactionAt;
pub const partyReactionAt = effects_mod.partyReactionAt;
pub const knockoutStart = effects_mod.knockoutStart;
pub const knockoutAt = effects_mod.knockoutAt;
pub const knockoutAfterHurt = effects_mod.knockoutAfterHurt;
pub const erosionPixels = effects_mod.erosionPixels;
pub const appendBackgroundWarp = effects_mod.appendBackgroundWarp;
pub const groundDepth = effects_mod.groundDepth;
pub const backgroundCaptureMinimum = effects_mod.backgroundCaptureMinimum;
pub const actorTransform = effects_mod.actorTransform;
