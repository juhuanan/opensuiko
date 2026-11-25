const std = @import("std");
const camera = @import("battle_camera");
const geometry = @import("battle_drops.zig");

pub const max_file_size = 16 * 1024 * 1024;
pub const Blend = enum { additive, subtractive, @"opaque" };
pub const Anchor = enum { caster, target, target_lane, world, each_target, party_member, screen };
pub const Point = geometry.Point;
pub const Entry = geometry.Entry;
pub const Sample = struct { quad_offsets: ?[4][3]i16 = null, noise_scale: bool = false, target_weight: [3]i32 = .{ 0, 0, 0 }, visible: bool = true, piece: ?u16 = null, position: [3]i32 = .{ 0, 0, 0 }, scale: [3]i32 = @splat(4096), angles: [3]i32 = .{ 0, 0, 0 }, node_angles: [3]i32 = .{ 0, 0, 1 }, size: i32 = 4096, tint: [3]u8 = @splat(127) };
pub const Variation = struct { draw: u8, modulus: u16, bias: i32 = 0, multiplier: i32 = 1 };
pub const Flight = struct { start: u16, updates: u16, target_height_q12: i32 = 0 };
pub const Object = struct { flight: ?Flight = null, screen_depth: ?u16 = null, random_node_angles: [3]?Variation = @splat(null), piece_track: ?u16 = null, origin_until: u16 = 0, particle_part: enum { primary, spark, pulse } = .primary, center_y: bool = true, particle_index: ?u8 = null, trail_index: ?u8 = null, member_index: u8 = 0, anchor: Anchor, track: u16, origin: [3]i32 = .{ 0, 0, 0 }, start: u16 = 0, position: [3]i32 = .{ 0, 0, 0 }, random_z: ?Variation = null, random_angle: ?Variation = null, random_node_angle: ?Variation = null, random_size: ?Variation = null, center_on_target: bool = false, blend: Blend = .additive };
pub const ColumnShape = struct { radius: i32, top_radius: i32, base_height: i32, height: i32, inner: [3]u8, outer: [3]u8 };
pub const Mesh = struct {
    segment_gaps: []const u16 = &.{},
    segment_gap: u16 = 0,
    shape_samples: []const ColumnShape = &.{},
    animated_angles: bool = false,
    strip_edges: []const []const [2][3]i16 = &.{},
    angles: [3]i32 = .{ 0, 0, 0 },
    opening: []const i16 = &.{},
    spread: []const i16 = &.{},
    blend: Blend = .additive,
    top_radius: ?i32 = null,
    base_heights: []const i32 = &.{},
    origin: [3]i32 = .{ 0, 0, 0 },
    kind: enum { fan, column, band, strip },
    anchor: Anchor,
    track: u16,
    start: u16,
    stop: u16,
    radius: i32,
    segments: u8,
    inner: [3]u8,
    outer: [3]u8,
    heights: []const i32 = &.{},
    depth: ?i32 = null,
    pub fn jsonStringify(self: Mesh, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(Mesh).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "segment_gaps")) self.segment_gaps.len != 0 else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const CameraEvent = struct { at: u16, updates: u16, target: camera.Block };
pub const PulseSpawn = struct { at: u16, index: u8 };
pub const Emitter = struct {
    loop_stop: u16 = 0,
    initial_warmup: u8 = 0,
    initial_phase: u8 = 0,
    oscillation: []const i32 = &.{},
    point_initial_scales: []const i32 = &.{},
    delay_bias: u16 = 0,
    landing_z: i32 = 0,
    initial_delays: bool = true,
    spawn_override: ?[3]i32 = null,
    spark_velocity_z: i32 = 0,
    spark_min_z: i32 = 0,
    velocity_x: i32 = 0,
    gravity: i32 = 0,
    bounce_divisor: u8 = 0,
    min_x: i32 = 0,
    spin_modulus: u16 = 0,
    focus_stride: u8 = 1,
    model_track: ?u16 = null,
    anchor: Anchor = .caster,
    repeat_size_range: u16 = 0,
    repeat_size_min: i32 = 0,
    focus_on_first: bool = false,
    spawn_height_min: u16 = 0,
    velocity_min: i32 = 0,
    velocity_range: u16 = 0,
    pulse_spawns: []const PulseSpawn = &.{},
    height_range: u8 = 0,
    contact_holds: bool = false,
    spark_stop: u16 = 0,
    fixed_positions: []const [3]i32 = &.{},
    target_height: bool = false,
    persistent_from: u8 = 0,
    spark_turn_at: u16 = 0,
    spark_turn_stop: u16 = 0,
    spark_turn_step: i32 = 0,
    spark_turn_limit: i32 = 0,
    focus_kick: i32 = 0,
    kind: enum { inward_points, inward_lines, rising_lines, rising_sprites, scheduled_sprites, falling_lines, lightning_bolts, scheduled_pulses, spherical_sprites, seeded_spheres, cycling_sprites, falling_trails, orbiting_sprites, drifting_sprites, bouncing_sprites, ballistic_sprites } = .inward_lines,
    repeat_until: u16 = 0,
    strike_at: u16 = 0,
    strike_radius: u8 = 0,
    spawn_at: []const u16 = &.{},
    flight_stop: u16 = 0,
    spark_track: u16 = 0,
    pulse_track: u16 = 0,
    spark_life_min: u8 = 0,
    spark_life_range: u8 = 0,
    pulse_life: u8 = 0,
    pulse_fade_at: u8 = 0,
    pulse_grow: i32 = 0,
    pulse_shrink: i32 = 0,
    origin: [3]i32 = .{ 0, 0, 0 },
    trail_min: u8 = 0,
    trail_range: u8 = 0,
    speed_range: u8 = 0,
    splash_track: u16 = 0,
    spawn_stop: u16 = 0,
    delay_modulus: u8 = 0,
    delay_stride: u8 = 1,
    initial_delay_draw: u8 = 0,
    particle_start: u8 = 0,
    trail_count: u8 = 0,
    repeat_radius: u8 = 0,
    spawn_clock: []const u16 = &.{},
    scale_track: u16 = 0,
    velocity_z: i32 = 0,
    life_max: u8 = 100,
    min_z: i32 = -200,
    start: u16,
    stop: u16,
    count: u8,
    radius: u16,
    roots: []const u16,
    color: [3]u8,
    pub fn jsonStringify(self: Emitter, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(Emitter).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "loop_stop")) self.loop_stop != 0 else if (comptime std.mem.eql(u8, name, "initial_warmup")) self.initial_warmup != 0 else if (comptime std.mem.eql(u8, name, "initial_phase")) self.initial_phase != 0 else if (comptime std.mem.eql(u8, name, "oscillation")) self.oscillation.len != 0 else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const Reaction = struct { active_samples: []const bool = &.{}, animation: u8 = 1, tints: []const [3]u8 = &.{}, release: ?u16 = null, start: u16, offsets: []const [2]i16, flash_frames: []const ?u8 = &.{} };
pub const Knockout = struct { entry: u16, duration: u16 };
pub const IdleFlashFrame = struct { ticks: u16, entries: [3]u16, normal: u16 };
pub const HurtPose = struct {
    source_attachment: ?[2]i16 = null,
    unite_entry: ?u16 = null,
    unite_white_entry: ?u16 = null,
    impact_offset: ?[2]i8 = null,
    sprite_height: ?u8 = null,
    white_entry: ?u16 = null,
    knockout: ?Knockout = null,
    id: []const u8,
    entry: u16,
    shock_entries: ?[3]u16 = null,
    center: ?[2]i16 = null,
    idle_center: ?[2]i16 = null,
    flash_entries: ?[3]u16 = null,
    idle_flash: ?struct { advances: bool, loop: bool, frames: []const IdleFlashFrame } = null,
    pub fn jsonStringify(self: HurtPose, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(HurtPose).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "source_attachment")) self.source_attachment != null else if (comptime std.mem.eql(u8, name, "idle_flash")) self.idle_flash != null else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const UniteImpact = struct { id: u8, frames: []const struct { entry: u16, ticks: u16 } };
pub const StatusKind = enum(u3) { poison, balloon_one, balloon_two, balloon_three, accuracy_reduced, sleep, rune_blocked, recovery };
pub const StatusIcon = struct {
    status: StatusKind,
    frames: []const struct { entry: u16, ticks: u16 },
    pub fn entryAt(self: StatusIcon, elapsed: u32) u16 {
        var duration: u32 = 0;
        for (self.frames) |frame| duration += frame.ticks;
        var remaining = elapsed % duration;
        for (self.frames) |frame| {
            if (remaining < frame.ticks) return frame.entry;
            remaining -= frame.ticks;
        }
        unreachable;
    }
};
pub const StatusAnchors = struct { id: []const u8, idle_pose: u16, hurt_pose: u16, offsets: []const [2]i16 };
pub const UniteMotion = struct {
    at: u16,
    updates: u16,
    home: bool,
    linear: bool,
    offset_q12: [3]i32,
    velocity_q12: [3]i32,
    absolute: bool = false,
    linear_offset: bool = false,
    pub fn jsonStringify(self: UniteMotion, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(UniteMotion).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "absolute") and !std.mem.eql(u8, name, "linear_offset")) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            } else if (@field(self, name)) {
                try writer.objectField(name);
                try writer.write(true);
            }
        }
        try writer.endObject();
    }
};
pub const UniteImpactSpawn = struct {
    at: u16,
    animation: u8,
    offset: [3]i16,
    centered: bool = true,
    pub fn jsonStringify(self: UniteImpactSpawn, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(UniteImpactSpawn).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "centered")) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            } else if (!self.centered) {
                try writer.objectField(name);
                try writer.write(false);
            }
        }
        try writer.endObject();
    }
};
pub const UniteStatusAttempt = struct { at: u16, kind: enum { enemy_sleep }, failure_percent: u8 };
pub const UniteSignal = struct { at: u16, bits: u16, set: bool };
pub const UnitePaletteCycle = struct { start: u16, stop: u16, period: u16, row: u8 };
pub const UniteReaction = struct {
    record: u8,
    variant: u8 = 0,
    duration: u16,
    blocker: ?[]const u8 = null,
    poses: []const struct { at: u16, animation: u8 },
    white: []const struct { at: u16, enabled: bool },
    offsets: []const struct { at: u16, offset: [2]i16 },
    motions: []const UniteMotion,
    impacts: []const UniteImpactSpawn,
    flip: ?struct { start: u16, stop: u16 } = null,
    focus_z_pulses: []const struct { at: u16, delta_q12: i32 } = &.{},
    locks_target: bool = true,
    retain_lock: bool = false,
    colors: []const struct { at: u16, rgb: [3]u8 } = &.{},
    status_attempts: []const UniteStatusAttempt = &.{},
    signals: []const UniteSignal = &.{},
    sounds: []const struct { at: u16, id: u16 } = &.{},
    palette_cycle: ?UnitePaletteCycle = null,
    pub fn jsonStringify(self: UniteReaction, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(UniteReaction).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "sounds")) self.sounds.len != 0 else if (comptime std.mem.eql(u8, name, "palette_cycle")) self.palette_cycle != null else if (comptime std.mem.eql(u8, name, "signals")) self.signals.len != 0 else if (comptime std.mem.eql(u8, name, "colors")) self.colors.len != 0 else if (comptime std.mem.eql(u8, name, "status_attempts")) self.status_attempts.len != 0 else if (comptime std.mem.eql(u8, name, "variant")) self.variant != 0 else if (comptime std.mem.eql(u8, name, "flip")) self.flip != null else if (comptime std.mem.eql(u8, name, "focus_z_pulses")) self.focus_z_pulses.len != 0 else if (comptime std.mem.eql(u8, name, "locks_target")) !self.locks_target else if (comptime std.mem.eql(u8, name, "retain_lock")) self.retain_lock else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const ReactionSample = struct { flip_y: bool = false, color: [3]u8 = @splat(128), animation: u8 = 1, visible: bool = true, tint: u8 = 128, blend: Blend = .@"opaque", elapsed: u16 = 0, offset: [2]i16, entry: ?u16 = null };

pub fn unitePosition(reaction: UniteReaction, origin_q12: [3]i32, home_q12: [3]i32, age: u32) [3]i32 {
    var position = origin_q12;
    for (reaction.motions, 0..) |motion, i| {
        if (age < motion.at) break;
        const until = if (i + 1 < reaction.motions.len) @min(age, reaction.motions[i + 1].at - 1) else age;
        const steps: i64 = @min(until - motion.at + 1, motion.updates);
        for (0..3) |axis| {
            const destination: i64 = if (motion.linear) (if (motion.linear_offset) home_q12[axis] +% motion.offset_q12[axis] else home_q12[axis]) else @as(i64, motion.offset_q12[axis]) + (if (motion.absolute or axis == 2) @as(i64, 0) else if (motion.home) home_q12[axis] else position[axis]);
            if (steps == motion.updates) {
                position[axis] = @intCast(destination);
            } else if (motion.linear) {
                position[axis] += @intCast(@divTrunc(destination - position[axis], motion.updates) * steps);
            } else {
                const velocity: i64 = motion.velocity_q12[axis];
                const duration: i64 = motion.updates;
                const acceleration = @divTrunc(destination - position[axis] - velocity * duration, @divTrunc(duration * (duration - 1), 2));
                position[axis] += @intCast(velocity * steps + @divTrunc(acceleration * steps * (steps - 1), 2));
            }
        }
    }
    return position;
}

pub fn uniteReactionAt(reaction: UniteReaction, pose: HurtPose, age: u32) ?ReactionSample {
    const absolute_tail = reaction.motions.len != 0 and reaction.motions[reaction.motions.len - 1].absolute;
    if (reaction.blocker != null or (age >= reaction.duration and !absolute_tail and !reaction.retain_lock)) return null;
    var result = ReactionSample{ .offset = .{ 0, 0 } };
    for (reaction.poses) |event| {
        if (age < event.at) break;
        result.animation = event.animation;
        result.elapsed = @intCast(@min(age - event.at, std.math.maxInt(u16)));
    }
    for (reaction.offsets) |event| {
        if (age < event.at) break;
        result.offset = event.offset;
    }
    if (reaction.flip) |flip| if (age >= flip.start and age < flip.stop) {
        result.flip_y = true;
        result.offset[1] = (pose.impact_offset orelse return null)[1];
    };
    for (reaction.colors) |event| {
        if (age < event.at) break;
        result.color = event.rgb;
    }
    var white = false;
    for (reaction.white) |event| {
        if (age < event.at) break;
        white = event.enabled;
    }
    if (result.animation == 1) {
        result.entry = if (white) pose.unite_white_entry orelse pose.white_entry else pose.unite_entry orelse pose.entry;
        if (reaction.palette_cycle) |cycle| if (age >= @as(u32, cycle.start) + 1 and age < cycle.stop) {
            const entries = (if (cycle.row == 1) pose.flash_entries else pose.shock_entries) orelse return null;
            result.entry = entries[((age - cycle.start) / cycle.period) % 3];
        };
    } else if (reaction.palette_cycle) |cycle| {
        if (cycle.row != 1) return null;
        const idle = pose.idle_flash orelse return null;
        var duration: u32 = 0;
        for (idle.frames) |frame| duration += frame.ticks;
        var remaining: u32 = if (!idle.advances) 0 else if (idle.loop) result.elapsed % duration else @min(result.elapsed, duration - 1);
        for (idle.frames) |frame| {
            if (remaining < frame.ticks) {
                result.entry = if (age >= @as(u32, cycle.start) + 1 and age < cycle.stop) frame.entries[((age - cycle.start) / cycle.period) % 3] else frame.normal;
                break;
            }
            remaining -= frame.ticks;
        }
    }
    return result;
}
pub const ScreenSample = struct { vertices: []const [4][2]i16, tint: u8, rgb: ?[3]u8 = null };
pub const ScreenLayer = struct { blend: Blend = .additive, entries: []const u16, samples: []const ?ScreenSample, copies: u8 = 1 };
pub const ScreenWash = struct { depth: i32 = 0, blend: Blend = .additive, colors: []const ?[3]u8 };
pub const ScaleNoise = struct { start: u16, stop: u16, modulus: u16, bias: i32 };
pub const Erosion = struct { entry: u16, start: u16, stop: u16, budget: u16, minimum_weight: u16, levels: []const u2, lower_present: []const bool, view_cells: []const u16, view_upper: []const bool, colors: []const [4]u8 };
pub const WarpFace = struct { indices: [4]u8, count: u8 };
pub const WarpGeometry = struct { source: []const [3]i16, destination: []const [3]i16 };
pub const BackgroundWarp = struct { anchor: Anchor = .world, samples: []const ?WarpGeometry, faces: []const WarpFace, depth: u16 = 380 };
pub const ActorMotion = struct { start: u16, returning: u16, updates: u16, destination: [3]i32, velocity: [3]i32, return_velocity: [3]i32, size_delta: []const i16, exclude_airborne: bool = true, exclude_protected: bool = true };
pub const ActorTransform = struct { position: [3]i32, size: i32 }; // Position is Q12; size4096 is unity.
pub const Program = struct {
    actor_motion: ?ActorMotion = null,
    background_warps: []const BackgroundWarp = &.{},
    erosion: ?Erosion = null,
    scale_noise: ?ScaleNoise = null,
    party_reaction: ?Reaction = null,
    reaction_center_switch: bool = false,
    screen_washes: []const ScreenWash = &.{},
    initial_draws_per_party: u8 = 0,
    screen_layers: []const ScreenLayer = &.{},
    group: bool = false,
    center_after_reaction: bool = true,
    focus_samples: []const ?[3]i32 = &.{},
    reaction: ?Reaction = null,
    impact: u16,
    duration: u16,
    initial_draws: u8,
    tracks: []const []const Sample,
    objects: []const Object,
    cameras: []const CameraEvent,
    meshes: []const Mesh,
    wash: []const [3]u8,
    wash_blend: Blend,
    emitter: ?Emitter = null,
    emitters: []const Emitter = &.{},
    pub fn emitterCount(self: Program) usize {
        return if (self.emitter != null) 1 else self.emitters.len;
    }
    pub fn emitterAt(self: *const Program, index: usize) *const Emitter {
        return if (self.emitter != null) &self.emitter.? else &self.emitters[index];
    }
    pub fn emitterForParticle(self: *const Program, index: u8) ?*const Emitter {
        for (0..self.emitterCount()) |i| {
            const emitter = self.emitterAt(i);
            if (index >= emitter.particle_start and @as(u16, index) < @as(u16, emitter.particle_start) + emitter.count) return emitter;
        }
        return null;
    }
};
pub const Spell = struct { id: []const u8, name: []const u8, program: ?Program = null, blocker: ?[]const u8 = null };
