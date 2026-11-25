//! Shared actor state for the instruction VM. Call stepActor in the scene's
//! established actor order; dispatch does not invent a second actor update.
const std = @import("std");
const vm = @import("battle_actor_program.zig");
const ScreenPoint = @import("battle_presentation.zig").ScreenPoint;
const camera = @import("battle_camera");
pub const ivy = @import("battle_ivy.zig");
pub const IvyVine = ivy.State;
pub const Frame = struct { pose: u16, updates: u16, attachment: [2]i16 = .{ 0, 0 } };
pub const Clip = struct { id: u16, advances: bool, loop: bool, semitransparent: bool = false, frames: []const Frame };
pub const Resource = struct {
    id: []const u8,
    pose_count: u16,
    clips: []const Clip,
    pub fn find(self: Resource, id: u16) ?Clip {
        for (self.clips) |clip| if (clip.id == id) return clip;
        return null;
    }
    pub fn validate(self: Resource) !void {
        if (self.id.len == 0 or self.id.len > 128 or self.pose_count == 0 or self.clips.len == 0 or self.clips.len > 256) return error.InvalidActorAnimations;
        for (self.clips, 0..) |clip, i| {
            if (clip.frames.len == 0 or clip.frames.len > 256) return error.InvalidActorAnimations;
            for (self.clips[0..i]) |prior| if (prior.id == clip.id) return error.InvalidActorAnimations;
            for (clip.frames) |frame| if (frame.pose >= self.pose_count or frame.updates == 0 or frame.updates > 256) return error.InvalidActorAnimations;
        }
    }
};
pub const Resources = struct {
    schema: []const u8,
    resources: []const Resource,
    pub fn find(self: Resources, id: []const u8) ?Resource {
        for (self.resources) |resource| if (std.mem.eql(u8, resource.id, id)) return resource;
        return null;
    }
    pub fn validate(self: Resources) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-actor-animations/1") or self.resources.len == 0 or self.resources.len > 256) return error.InvalidActorAnimations;
        for (self.resources, 0..) |resource, i| {
            try resource.validate();
            for (self.resources[0..i]) |prior| if (std.mem.eql(u8, prior.id, resource.id)) return error.InvalidActorAnimations;
        }
    }
};
pub fn loadResources(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Resources) {
    if (bytes.len > 16 * 1024 * 1024) return error.InvalidActorAnimations;
    const parsed = try std.json.parseFromSlice(Resources, allocator, bytes, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
pub const Palette = union(enum) { resource: void, shared: u8 };
const PaletteCycleState = struct { index: u2 = 0, remaining: u16 };
pub const BlueTrail = struct {
    points: [8][2]f32,
    pose: u16,
    next: u3 = 0,
    visible: bool = false,
    depth: f32,
    pub const Sample = struct { position: [2]f32, pose: u16, color: [3]u8 };
    pub fn newest(self: BlueTrail, age: u3) Sample {
        const slot = self.next -% 1 -% age;
        const shade: u8 = @intCast(@as(u16, 255) * (7 - @as(u16, age)) / 7);
        return .{ .position = self.points[slot], .pose = self.pose, .color = .{ shade, shade, 255 } };
    }
};
pub const Movement = struct { destination: [3]i32, remaining: u16 };
const CrowDive = struct {
    points: [3][3]i32 = @splat(@splat(0)),
    age: i32 = 0,
    initialized: bool = false,
};
const RabbitReturn = struct { delta_q12: [3]i32 = .{ 0, 0, 0 }, hop: u3 = 0 };
const ShadowFade = struct { updates: u16 = 0, origin: [3]i32 = @splat(0) };
const MirageWorker = struct {
    kind: enum { vanish_left, fade, vanish_right },
    phase_updates: u16,
    offset_q12: i32,
    delta_q12: [3]i32 = .{ 0, 0, 0 },
    origin_q12: [3]i32 = @splat(0),
    timer: u16 = 0,
};
pub const MirageVisual = struct {
    pub const max_copies = 7;
    pose: u16,
    crop: [4]u8,
    copies: u8,
    modulation: u8,
    spread_step_q12: u16,
};
pub const RegionalBinding = struct {
    id: []const u8,
    target_row: enum { front, any_row },
    front_roll_threshold: u8,
    special_roll_threshold: ?u8 = null,
    special_delay_updates: ?u16 = null,
    special_hits: u8 = 0,
    special_recipient_return: ?[]const u8 = null,
    shrink_step_q12: i32 = 0,
    shrink_min_q12: i32 = 0,
    shrink_spin_angle: i16 = 0,
    expand_step_q12: i32 = 0,
    expand_target_q12: i32 = 0,
    direct_attack: bool = false,
    fade_updates: u16 = 0,
    shadow_column: ?struct {
        segments: u8,
        radial_start_q12: u16,
        step_q12: u16,
        shape: @import("battle_spell_scene_types.zig").ColumnShape,
    } = null,
    wait_100: bool = false,
    camera_shake_z_q12: i32 = 0,
    rear_triggers_special: bool = false,
    vanish_phase_updates: u16 = 0,
    vanish_offset_q12: i32 = 0,
    mirage_visual: ?MirageVisual = null,

    pub fn jsonStringify(self: RegionalBinding, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(RegionalBinding).@"struct".field_names) |name| {
            // Preserve the saved content digest when the visuals are absent.
            const emit = if (comptime std.mem.eql(u8, name, "shadow_column")) self.shadow_column != null else if (comptime std.mem.eql(u8, name, "mirage_visual")) self.mirage_visual != null else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const Actor = struct {
    graphic_record: ?u8 = null,
    resource: ?Resource = null,
    regional: ?*const RegionalBinding = null,
    external_attachment: ?[2]i16 = null,
    home_q12: [3]i32,
    position_q12: [3]i32,
    owner: ?u16 = null,
    animation: u16 = 0,
    frame: usize = 0,
    frame_remaining: u16 = 0,
    animating: bool = false,
    movement: ?Movement = null,
    retained_destination_q12: ?[3]i32 = null,
    velocity_q12: [3]i32 = .{ 0, 0, 0 },
    acceleration_q12: [3]i32 = .{ 0, 0, 0 },
    projectile: ?enum { aimed, spinning, fixed, rabbit_spin } = null,
    crow_dive: ?CrowDive = null,
    ivy_vine: ?IvyVine = null,
    rabbit_return: ?RabbitReturn = null,
    suikomi_phase: ?enum { shrink_spin, spit_expand } = null,
    pending_tail_return: bool = false,
    shadow_fade: ?ShadowFade = null,
    mirage_worker: ?MirageWorker = null,
    draw_size_q12: i32 = 4096,
    draw_angles: [3]i16 = .{ 0, 0, 0 },
    machine: ?vm.Machine = null,
    signals: u16 = 0,
    shared_value: i16 = 0,
    record_flags: u8 = 0,
    highlights: u8 = 0,
    // Completion request; the scene owns coordinator gating and the VM continues to HALT.
    released: bool = false,
    visible: bool = true,
    translucent: bool = false,
    palette: Palette = .{ .resource = {} },
    color: ?[3]u8 = null,
    palette_cycle_config: ?vm.PaletteCycle = null,
    palette_cycle_state: ?PaletteCycleState = null,
    palette_cycle_active: bool = false,
    reaction_callback: ?enum { airborne, shadow_airborne, decoy, spin, camera_facing } = null,
    blue_trail_active: bool = false,
    blue_trail: ?BlueTrail = null,
    retired: bool = false,
    has_draw_record: bool = true,
    baseline_offset: [2]i16 = .{ 0, 0 },
    screen_offset: [2]i8 = .{ 0, 0 },
    offset_destination: [2]i32 = .{ 0, 0 },
    pub fn anchor(position_q12: [3]i32, home_q12: [3]i32, source_attachment: ?[2]i16) Actor {
        return .{ .home_q12 = home_q12, .position_q12 = position_q12, .external_attachment = source_attachment, .visible = false, .has_draw_record = false };
    }
    pub fn attachment(self: Actor) ![2]i16 {
        if (self.resource != null) return self.currentFrame().attachment;
        return self.external_attachment orelse error.MissingActorAttachment;
    }
    pub fn init(resource: Resource, home_q12: [3]i32) !Actor {
        return initAnimation(resource, home_q12, 0);
    }
    pub fn initAnimation(resource: Resource, home_q12: [3]i32, animation: u16) !Actor {
        try resource.validate();
        var result = Actor{ .resource = resource, .home_q12 = home_q12, .position_q12 = home_q12 };
        try result.selectAnimation(animation);
        return result;
    }
    pub fn currentFrame(self: Actor) Frame {
        return self.resource.?.find(self.animation).?.frames[self.frame];
    }
    pub fn jsonStringify(self: Actor, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(Actor).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "color")) {
                if (self.color != null) {
                    try writer.objectField(name);
                    try writer.write(self.color.?);
                }
            } else if (comptime std.mem.eql(u8, name, "rabbit_return")) {
                if (self.rabbit_return != null) {
                    try writer.objectField(name);
                    try writer.write(self.rabbit_return.?);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn selectAnimation(self: *Actor, id: u16) !void {
        const resource = self.resource orelse return error.MissingActorResource;
        const clip = resource.find(id) orelse return error.MissingActorAnimation;
        self.animation = id;
        self.frame = 0;
        self.frame_remaining = clip.frames[0].updates;
        self.animating = clip.advances;
    }
    pub fn advancePaletteCycle(self: *Actor) !void {
        const config = self.palette_cycle_config orelse return error.MissingPaletteCycleConfig;
        switch (self.shared_value) {
            0 => {
                self.palette_cycle_state = .{ .remaining = config.updates };
                self.shared_value = 1;
            },
            1 => {
                const state = if (self.palette_cycle_state) |*value| value else return error.InvalidPaletteCycleState;
                state.remaining -= 1;
                if (state.remaining == 0) {
                    state.remaining = config.updates;
                    state.index = if (state.index == 2) 0 else state.index + 1;
                }
                self.palette = .{ .shared = config.variants[state.index] };
            },
            99 => {
                self.palette = .{ .resource = {} };
                self.palette_cycle_state = null;
                self.palette_cycle_active = false;
            },
            else => {},
        }
    }
    pub fn advanceAnimation(self: *Actor) void {
        if (!self.animating) return;
        self.frame_remaining -= 1;
        if (self.frame_remaining != 0) return;
        const clip = self.resource.?.find(self.animation).?;
        if (self.frame + 1 < clip.frames.len) self.frame += 1 else if (clip.loop) self.frame = 0 else self.animating = false;
        self.frame_remaining = clip.frames[self.frame].updates;
    }
};
pub const External = struct {
    context: *anyopaque,
    command: *const fn (*anyopaque, u16, vm.Command, bool) anyerror!bool,
    after_actor: ?*const fn (*anyopaque, u16) anyerror!void = null,
    // Called before this update's regular projection; return the retained screen position.
    previous_screen_position: ?*const fn (*anyopaque, u16) anyerror!ScreenPoint = null,
    release_actor: ?*const fn (*anyopaque, u16) anyerror!void = null,
    hold_coordinator_dispatch: ?*const fn (*anyopaque, u16) anyerror!void = null,
    tail_return: ?*const fn (*anyopaque, u16) anyerror!void = null,
    // Consume the source variance draw; auxiliary targets receive no HP write.
    decoy_contact: ?*const fn (*anyopaque, u16, u16) anyerror!void = null,
};
pub const Library = struct { programs: vm.Packet, resources: Resources };
pub const ParticipantBinding = struct { family: enum { physical, counter, enemy_magic, commander, enemy_wave } = .physical, leader: u8, resource: u8, program: ?u16 = null };
pub const FanBinding = struct { animation: u16, rolls: [5]i16, node_angles: [3]i16, velocity_q12: i32, anchor_z: i16, signal: u16 };
pub const HitCamera = struct { updates: u16, target: camera.Block };
pub const MemberBinding = struct {
    fan: ?FanBinding = null,
    hit_camera: ?HitCamera = null,
    id: []const u8,
    programs: []const []const u8,
    start_after: u16 = 0,
    reaction_on_hit: bool = false,
    reaction_variant: u8 = 0,
    reaction_group: bool = false,
    entry_program: ?[]const u8 = null,
    loop_program: ?[]const u8 = null,
    deferred_entry: bool = false,
    pub fn jsonStringify(self: MemberBinding, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(MemberBinding).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "hit_camera")) self.hit_camera != null else if (comptime std.mem.eql(u8, name, "deferred_entry")) self.deferred_entry else if (comptime std.mem.eql(u8, name, "fan")) self.fan != null else if (comptime std.mem.eql(u8, name, "start_after")) self.start_after != 0 else if (comptime std.mem.eql(u8, name, "reaction_on_hit")) self.reaction_on_hit else if (comptime std.mem.eql(u8, name, "reaction_variant")) self.reaction_variant != 0 else if (comptime std.mem.eql(u8, name, "reaction_group")) self.reaction_group else if (comptime std.mem.eql(u8, name, "entry_program")) self.entry_program != null else if (comptime std.mem.eql(u8, name, "loop_program")) self.loop_program != null else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const TransitionDispatch = struct { member: u8, program: []const u8 };
pub const Transition = struct { trigger_member: u8, signal: u16, dispatches: []const TransitionDispatch };
pub const SceneController = struct {
    mode: enum { beauty, owner_clock, orbit } = .beauty,
    orbit: ?struct {
        anchor_member: u8,
        hold_updates: u16,
        divisor: u8,
        base_z_q12: i32,
        heights_q12: []const i32,
        sounds: []const struct { at: u16, id: u16 },
    } = null,
    return_at: ?u16 = null,
    vfx: []const u8,
    trigger_member: u8,
    signal: u16,
    recipient_at: u16,
    recipient_variant: u8,
    recipient_rolls: []const i16,
    damage_at: u16,
    cleanup_at: u16,
    pub fn jsonStringify(self: SceneController, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(SceneController).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "mode")) self.mode != .beauty else if (comptime std.mem.eql(u8, name, "return_at")) self.return_at != null else if (comptime std.mem.eql(u8, name, "orbit")) self.orbit != null else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const UniteBinding = struct {
    wave_heights: ?@import("battle_unite_trick.zig").Heights = null,
    beat_child: ?vm.Child = null,
    target_queue: ?@import("battle_unite_queue.zig").Timing = null,
    controller: ?SceneController = null,
    record: u8,
    name: []const u8,
    members: []const MemberBinding,
    return_program: ?[]const u8,
    dispatch_after: ?u16 = null,
    assist_after_damage: bool = false,
    transition: ?Transition = null,
    embedded_returns: bool = false,
    damage_member: ?u8 = null,
    damage_signal: u16 = 2,
    damage_target_signal: ?u16 = null,
    damage_reaction: bool = true,
    impact_effect: ?u8 = null,
    pub fn jsonStringify(self: UniteBinding, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(UniteBinding).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "wave_heights")) self.wave_heights != null else if (comptime std.mem.eql(u8, name, "beat_child")) self.beat_child != null else if (comptime std.mem.eql(u8, name, "target_queue")) self.target_queue != null else if (comptime std.mem.eql(u8, name, "impact_effect")) self.impact_effect != null else if (comptime std.mem.eql(u8, name, "damage_target_signal")) self.damage_target_signal != null else if (comptime std.mem.eql(u8, name, "damage_reaction")) !self.damage_reaction else if (comptime std.mem.eql(u8, name, "controller")) self.controller != null else if (comptime std.mem.eql(u8, name, "dispatch_after")) self.dispatch_after != null else if (comptime std.mem.eql(u8, name, "assist_after_damage")) self.assist_after_damage else if (comptime std.mem.eql(u8, name, "transition")) self.transition != null else if (comptime std.mem.eql(u8, name, "embedded_returns")) self.embedded_returns else if (comptime std.mem.eql(u8, name, "damage_member")) self.damage_member != null else if (comptime std.mem.eql(u8, name, "damage_signal")) self.damage_signal != 2 else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};

const bundle = @import("battle_actor_host/bundle.zig");
const runtime = @import("battle_actor_host/runtime.zig");
pub const Bundle = bundle.Bundle;
pub const loadBundle = bundle.loadBundle;
pub const Runtime = runtime.Runtime;
