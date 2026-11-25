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
const Movement = struct { destination: [3]i32, remaining: u16 };
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
    fn selectAnimation(self: *Actor, id: u16) !void {
        const resource = self.resource orelse return error.MissingActorResource;
        const clip = resource.find(id) orelse return error.MissingActorAnimation;
        self.animation = id;
        self.frame = 0;
        self.frame_remaining = clip.frames[0].updates;
        self.animating = clip.advances;
    }
    fn advancePaletteCycle(self: *Actor) !void {
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
    fn advanceAnimation(self: *Actor) void {
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
pub const Bundle = struct {
    schema: []const u8,
    programs: vm.Packet,
    animations: Resources,
    unites: []const UniteBinding,
    physical: ?[]const @import("battle_physical.zig").Binding = null,
    counter: ?@import("battle_counter.zig").Bindings = null,
    enemy_magic: ?@import("battle_enemy_magic.zig").Binding = null,
    commander: ?@import("battle_commander.zig").Binding = null,
    group_orders: ?[]const @import("battle_commander.zig").Binding = null,
    enemy_wave: ?@import("battle_enemy_wave.zig").Binding = null,
    enemy_area_magic: ?[]const @import("battle_enemy_magic.zig").AreaBinding = null,
    enemy_regional: ?[]const RegionalBinding = null,
    pub fn jsonStringify(self: Bundle, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "schema", "programs", "animations", "unites" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.physical) |bindings| {
            try writer.objectField("physical");
            try writer.write(bindings);
        }
        if (self.counter) |bindings| {
            try writer.objectField("counter");
            try writer.write(bindings);
        }
        if (self.enemy_magic) |binding| {
            try writer.objectField("enemy_magic");
            try writer.write(binding);
        }
        if (self.commander) |binding| {
            try writer.objectField("commander");
            try writer.write(binding);
        }
        if (self.group_orders) |bindings| {
            try writer.objectField("group_orders");
            try writer.write(bindings);
        }
        if (self.enemy_wave) |binding| {
            try writer.objectField("enemy_wave");
            try writer.write(binding);
        }
        if (self.enemy_area_magic) |bindings| {
            try writer.objectField("enemy_area_magic");
            try writer.write(bindings);
        }
        if (self.enemy_regional) |bindings| {
            try writer.objectField("enemy_regional");
            try writer.write(bindings);
        }
        try writer.endObject();
    }
    pub fn regionalFor(self: Bundle, id: []const u8) ?*const RegionalBinding {
        for (self.enemy_regional orelse return null) |*binding| if (std.mem.eql(u8, binding.id, id)) return binding;
        return null;
    }
    pub fn areaMagicFor(self: Bundle, id: []const u8) ?@import("battle_enemy_magic.zig").AreaBinding {
        for (self.enemy_area_magic orelse return null) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
        return null;
    }
    pub fn commanderFor(self: Bundle, id: []const u8) ?@import("battle_commander.zig").Binding {
        if (self.commander) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
        for (self.group_orders orelse return null) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
        return null;
    }
    pub fn physicalPacket(self: Bundle) ?@import("battle_physical.zig").Packet {
        return .{ .schema = "suikoden-physical-actors/2", .programs = self.programs, .animations = self.animations, .techniques = self.physical orelse return null };
    }
    pub fn counterPacket(self: Bundle) ?@import("battle_counter.zig").Packet {
        const bindings = self.counter orelse return null;
        return .{ .schema = if (bindings.hasSpecialReturnCamera()) "suikoden-counter-actors/13" else if (bindings.hasSpecialReturn()) "suikoden-counter-actors/12" else if (bindings.hasProjectileCamera()) "suikoden-counter-actors/11" else if (bindings.hasProjectile()) "suikoden-counter-actors/10" else if (bindings.party_melee != null) "suikoden-counter-actors/9" else if (bindings.hasSpecial()) "suikoden-counter-actors/8" else if (bindings.ranged != null and bindings.ranged.?.critical_camera != null) "suikoden-counter-actors/7" else if (bindings.ranged != null) "suikoden-counter-actors/6" else if (bindings.cooperation != null) "suikoden-counter-actors/5" else if (bindings.cover != null) "suikoden-counter-actors/4" else if (bindings.melee != null) "suikoden-counter-actors/3" else if (bindings.parries != null) "suikoden-counter-actors/2" else "suikoden-counter-actors/1", .programs = self.programs, .animations = self.animations, .defenders = bindings.defenders, .enemies = bindings.enemies, .parries = bindings.parries, .melee = bindings.melee, .cover = bindings.cover, .cooperation = bindings.cooperation, .ranged = bindings.ranged, .party_melee = bindings.party_melee };
    }
    pub fn digest(self: Bundle) ![32]u8 {
        const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, self, .{});
        defer std.heap.page_allocator.free(bytes);
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
        return result;
    }
    pub fn library(self: Bundle) Library {
        return .{ .programs = self.programs, .resources = self.animations };
    }
    pub fn find(self: *const Bundle, record: u8) ?*const UniteBinding {
        for (self.unites) |*unite| if (unite.record == record) return unite;
        return null;
    }
    fn uniteActorsSchemaVersion(schema: []const u8) ?u8 {
        const prefix = "suikoden-unite-actors/";
        if (!std.mem.startsWith(u8, schema, prefix)) return null;
        const suffix = schema[prefix.len..];
        if (suffix.len == 0 or suffix[0] < '1' or suffix[0] > '9') return null;
        for (suffix) |ch| if (ch < '0' or ch > '9') return null;
        const version = std.fmt.parseInt(u8, suffix, 10) catch return null;
        return if (version <= 40) version else null;
    }
    pub fn validate(self: Bundle) !void {
        const schema_version = uniteActorsSchemaVersion(self.schema) orelse return error.InvalidUniteBindings;
        if (self.unites.len != 32) return error.InvalidUniteBindings;
        const standalone22 = schema_version >= 22 and self.physical == null and self.counter == null and self.enemy_magic == null and self.commander == null and self.group_orders == null and self.enemy_wave == null and self.enemy_area_magic == null and self.enemy_regional == null;
        if ((self.enemy_area_magic != null) != (schema_version >= 39 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.enemy_regional != null) != (schema_version >= 40 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.enemy_wave != null) != (schema_version >= 38 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.group_orders != null) != (schema_version >= 37 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasProjectile()) != (schema_version >= 33 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasSpecialReturnCamera()) != (schema_version >= 36 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasSpecialReturn()) != (schema_version >= 35 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasProjectileCamera()) != (schema_version >= 34 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.commander != null) != (schema_version >= 32 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.physical != null) != (schema_version >= 11 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null) != (schema_version >= 12 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.parries != null) != (schema_version >= 13 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.melee != null) != (schema_version >= 14 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.enemy_magic != null) != ((schema_version == 15 or schema_version == 17 or schema_version >= 19) and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.cover != null) != (schema_version >= 16 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.cooperation != null) != (schema_version >= 18 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.ranged != null) != (schema_version >= 20 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.ranged != null and self.counter.?.ranged.?.critical_camera != null) != (schema_version >= 21 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.hasSpecial()) != (schema_version >= 25 and !standalone22)) return error.InvalidUniteBindings;
        if ((self.counter != null and self.counter.?.party_melee != null) != (schema_version >= 31 and !standalone22)) return error.InvalidUniteBindings;
        if (self.physicalPacket()) |packet| try packet.validate();
        if (self.counterPacket()) |packet| try packet.validate();
        const target_signals = schema_version >= 10;
        const controllers = schema_version >= 9;
        const deferred = schema_version >= 8;
        const signals = schema_version >= 7;
        const fans = schema_version >= 6;
        const grouped = schema_version >= 5;
        const phased = schema_version >= 4;
        const variants = schema_version >= 3;
        const scheduled = schema_version >= 2;
        try self.programs.validate();
        try self.animations.validate();
        if (self.enemy_wave) |binding| {
            try binding.validate(self.library());
            try self.validateProgram(self.animations.find(binding.id).?, binding.owner_program);
        }
        if (self.commander) |binding| {
            if (!std.mem.eql(u8, binding.id, "beast_commander")) return error.InvalidEnemyOrderBinding;
            try binding.validate(self.library());
            const resource = self.animations.find(binding.id).?;
            try self.validateProgram(resource, binding.order_program);
            try self.validateProgram(resource, binding.solo_program.?);
            for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, binding.recipient_program.?);
        }
        if (self.group_orders) |bindings| {
            if (bindings.len != 1) return error.InvalidEnemyOrderBinding;
            for (bindings) |binding| {
                if (!std.mem.eql(u8, binding.id, "whip_wolf")) return error.InvalidEnemyOrderBinding;
                try binding.validate(self.library());
                try self.validateProgram(self.animations.find(binding.id).?, binding.order_program);
            }
        }
        if (self.enemy_magic) |binding| {
            try binding.validate();
            const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
            try self.validateProgram(resource, binding.owner_program);
            if (self.programs.find(binding.recipient_program) == null) return error.MissingUniteProgram;
            for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, binding.recipient_program);
        }
        if (self.enemy_area_magic) |bindings| {
            if (schema_version < 39 or bindings.len != 3) return error.InvalidEnemyMagicBinding;
            for (bindings, 0..) |binding, i| {
                try binding.validate();
                for (bindings[0..i]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidEnemyMagicBinding;
                const resource = self.animations.find(binding.id) orelse return error.MissingActorResource;
                try self.validateProgram(resource, binding.owner_program);
                if (self.programs.find(binding.recipient_program) == null) return error.MissingUniteProgram;
                for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, binding.recipient_program);
                if (binding.wave_recipient_program) |wave_program| {
                    if (self.programs.find(wave_program) == null) return error.MissingUniteProgram;
                    for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, wave_program);
                }
            }
        }
        if (self.counter) |counter| if (counter.melee) |melee| {
            for (melee.party_reactions) |party| {
                if (schema_version >= 40) {
                    const ret = party.return_program orelse return error.InvalidCounterBindings;
                    try self.validateProgram(self.animations.find(party.id) orelse return error.MissingActorResource, ret);
                } else if (party.return_program != null) return error.InvalidCounterBindings;
            }
        };
        if (self.enemy_regional) |bindings| {
            if (schema_version < 40 or bindings.len != 4 or self.counter == null or self.counter.?.melee == null) return error.InvalidUniteBindings;
            for (bindings, 0..) |binding, i| {
                if (binding.id.len == 0 or binding.id.len > 128) return error.InvalidUniteBindings;
                if (binding.front_roll_threshold > 100) return error.InvalidUniteBindings;
                if (binding.special_hits > 0 and (binding.shrink_step_q12 <= 0 or binding.shrink_min_q12 <= 0 or binding.expand_step_q12 <= 0 or binding.expand_target_q12 <= binding.shrink_min_q12)) return error.InvalidUniteBindings;
                if (binding.direct_attack and (binding.fade_updates == 0 or binding.camera_shake_z_q12 <= 0 or binding.camera_shake_z_q12 > 32767 * 4096)) return error.InvalidUniteBindings;
                if (binding.shadow_column) |column| {
                    if (!binding.direct_attack or column.segments < 3 or column.segments > 32 or
                        column.radial_start_q12 > 4096 or column.step_q12 == 0 or column.step_q12 > 4096 or
                        column.shape.radius < 0 or column.shape.radius > 1024 or column.shape.top_radius < 0 or column.shape.top_radius > 1024 or
                        @abs(column.shape.base_height) > 1024 or @abs(column.shape.height) > 1024) return error.InvalidUniteBindings;
                }
                if (binding.rear_triggers_special and (binding.vanish_phase_updates == 0 or binding.vanish_offset_q12 < 0)) return error.InvalidUniteBindings;
                if (binding.mirage_visual) |visual| {
                    if (!binding.rear_triggers_special or visual.copies == 0 or visual.copies > MirageVisual.max_copies or visual.copies % 2 == 0 or
                        visual.crop[2] == 0 or visual.crop[3] == 0 or visual.modulation == 0 or visual.modulation > 128 or
                        visual.spread_step_q12 == 0 or visual.spread_step_q12 > 4096) return error.InvalidUniteBindings;
                }
                for (bindings[0..i]) |prior| if (std.mem.eql(u8, prior.id, binding.id)) return error.InvalidUniteBindings;
                _ = self.animations.find(binding.id) orelse return error.MissingActorResource;
                var found_melee = false;
                for (self.counter.?.melee.?.enemies) |melee| if (std.mem.eql(u8, melee.id, binding.id)) {
                    found_melee = true;
                    break;
                };
                if (!found_melee) return error.InvalidCounterBindings;
                if (binding.special_recipient_return) |ret| {
                    if (self.programs.find(ret) == null) return error.MissingUniteProgram;
                    for (self.counter.?.melee.?.party_reactions) |party| try self.validateProgram(self.animations.find(party.id).?, ret);
                }
            }
        }
        for (self.unites, 0..) |unite, index| {
            if (unite.record >= 32 or unite.name.len == 0 or unite.name.len > 128 or unite.members.len < 2 or unite.members.len > 4) return error.InvalidUniteBindings;
            if (unite.impact_effect != null and (schema_version < 24 or unite.damage_member == null or unite.controller != null or unite.dispatch_after == null)) return error.InvalidUniteBindings;
            if (!unite.damage_reaction and !target_signals) return error.InvalidUniteBindings;
            if (unite.damage_target_signal) |signal| {
                if (!target_signals or @popCount(signal) != 1 or unite.damage_member != null or unite.controller != null or unite.dispatch_after == null or unite.damage_signal != 2) return error.InvalidUniteBindings;
            }
            if (unite.controller) |spec| {
                if (!controllers or spec.vfx.len == 0 or spec.vfx.len > 40 or spec.trigger_member >= unite.members.len or @popCount(spec.signal) != 1 or spec.recipient_variant > 3 or spec.cleanup_at > 1000 or unite.dispatch_after == null or unite.return_program == null or unite.embedded_returns or unite.transition != null or unite.damage_member != null or unite.assist_after_damage) return error.InvalidUniteBindings;
                switch (spec.mode) {
                    .beauty => if (spec.orbit != null or spec.return_at != null or spec.recipient_at == 0 or spec.recipient_at >= spec.damage_at or @as(u32, spec.damage_at) + 1 != spec.cleanup_at or spec.recipient_rolls.len == 0 or spec.recipient_rolls.len > spec.damage_at - spec.recipient_at) return error.InvalidUniteBindings,
                    .owner_clock => if (spec.orbit != null or schema_version < 22 or spec.return_at == null or spec.damage_at == 0 or spec.damage_at >= spec.return_at.? or @as(u32, spec.return_at.?) + 1 != spec.cleanup_at or spec.recipient_at != 0 or spec.recipient_variant != 0 or spec.recipient_rolls.len != 0 or !unite.damage_reaction) return error.InvalidUniteBindings,
                    .orbit => {
                        const orbit = spec.orbit orelse return error.InvalidUniteBindings;
                        if (schema_version < 26 or spec.return_at != null or orbit.anchor_member >= unite.members.len or orbit.hold_updates == 0 or orbit.divisor == 0 or orbit.heights_q12.len == 0 or orbit.heights_q12.len > 256 or @as(u32, orbit.hold_updates) + orbit.heights_q12.len >= spec.damage_at or spec.recipient_at <= orbit.hold_updates or spec.recipient_at >= spec.damage_at or spec.recipient_variant == 0 or spec.recipient_rolls.len != 0 or @as(u32, spec.damage_at) + 1 != spec.cleanup_at or unite.damage_reaction) return error.InvalidUniteBindings;
                        if (@abs(@as(i64, orbit.base_z_q12)) > 32768 * 4096 or orbit.sounds.len > 16) return error.InvalidUniteBindings;
                        for (orbit.heights_q12) |height| if (@abs(@as(i64, height)) > 32768 * 4096) return error.InvalidUniteBindings;
                        for (orbit.sounds, 0..) |sound, i| if (sound.at == 0 or sound.at >= spec.cleanup_at or (i > 0 and sound.at <= orbit.sounds[i - 1].at)) return error.InvalidUniteBindings;
                    },
                }
                for (unite.members) |member| if (member.reaction_on_hit or member.deferred_entry or member.fan != null) return error.InvalidUniteBindings;
                for (spec.recipient_rolls) |roll| if (roll < -4096 or roll > 4096) return error.InvalidUniteBindings;
            }
            for (self.unites[0..index]) |prior| if (prior.record == unite.record) return error.InvalidUniteBindings;
            if (@popCount(unite.damage_signal) != 1 or (unite.damage_signal != 2 and (!signals or unite.damage_member == null))) return error.InvalidUniteBindings;
            if (unite.damage_member) |member| if (!grouped or member >= unite.members.len or (unite.damage_signal == 2 and unite.members[member].reaction_on_hit)) return error.InvalidUniteBindings;
            if (unite.embedded_returns and (!phased or unite.return_program != null)) return error.InvalidUniteBindings;
            if (schema_version >= 29 and unite.record == 14 and unite.dispatch_after != null and unite.wave_heights == null) return error.InvalidUniteBindings;
            if (unite.wave_heights) |heights| {
                if (schema_version < 29 or unite.record != 14 or unite.members.len != 2 or unite.dispatch_after != 1 or unite.return_program == null or !std.mem.eql(u8, unite.return_program.?, "common/unite_return") or unite.controller != null or unite.target_queue != null or unite.beat_child != null or unite.transition != null or unite.embedded_returns or unite.damage_member != null or unite.damage_target_signal != null or !unite.damage_reaction or unite.assist_after_damage or unite.impact_effect != null) return error.InvalidUniteBindings;
                _ = @import("battle_unite_trick.zig").State.init(heights) catch return error.InvalidUniteBindings;
                for (unite.members) |member| if (member.entry_program == null or member.programs.len != 1 or member.reaction_on_hit or member.deferred_entry or member.fan != null or member.loop_program != null or member.start_after != 0) return error.InvalidUniteBindings;
                const resource = self.animations.find(unite.members[1].id) orelse return error.MissingActorResource;
                const clip = resource.find(19) orelse return error.MissingActorAnimation;
                if (!clip.advances) return error.InvalidUniteBindings;
            }
            if (schema_version >= 28 and unite.record == 27 and unite.dispatch_after != null and unite.beat_child == null) return error.InvalidUniteBindings;
            if (unite.beat_child) |child| {
                if (schema_version < 28 or unite.record != 27 or unite.members.len != 2 or unite.dispatch_after != 1 or !unite.embedded_returns or unite.controller != null or unite.target_queue != null or unite.damage_member != 1 or unite.damage_signal != 2 or !unite.damage_reaction or unite.damage_target_signal != null or unite.assist_after_damage or unite.impact_effect != null) return error.InvalidUniteBindings;
                if (!std.mem.eql(u8, child.resource, unite.members[1].id) or child.owner != .self or child.home != .parent_owner or child.draw_record) return error.InvalidUniteBindings;
                const transition = unite.transition orelse return error.InvalidUniteBindings;
                if (transition.trigger_member != 0 or transition.signal != 16 or transition.dispatches.len != 1 or transition.dispatches[0].member != 1) return error.InvalidUniteBindings;
                for (unite.members, 0..) |member, ordinal| if (member.entry_program == null or member.deferred_entry or member.loop_program != null or member.start_after != 0 or member.fan != null or member.reaction_group or member.reaction_on_hit != (ordinal == 0) or member.reaction_variant != (if (ordinal == 0) @as(u8, 1) else 0)) return error.InvalidUniteBindings;
                const resource = self.animations.find(child.resource) orelse return error.MissingActorResource;
                if (resource.find(child.animation) == null) return error.MissingActorAnimation;
                try self.validateProgram(resource, child.program);
            }
            if (unite.transition) |transition| {
                if (!phased or transition.trigger_member >= unite.members.len or @popCount(transition.signal) != 1 or transition.dispatches.len == 0 or transition.dispatches.len > unite.members.len) return error.InvalidUniteBindings;
                for (transition.dispatches, 0..) |dispatch, ordinal| {
                    if (dispatch.member >= unite.members.len) return error.InvalidUniteBindings;
                    for (transition.dispatches[0..ordinal]) |prior| if (prior.member == dispatch.member) return error.InvalidUniteBindings;
                    var listed = false;
                    for (unite.members[dispatch.member].programs) |id| listed = listed or std.mem.eql(u8, id, dispatch.program);
                    if (!listed) return error.InvalidUniteBindings;
                    const program = self.programs.find(dispatch.program) orelse return error.MissingUniteProgram;
                    // Deferred dispatch must not change callback-visible signals or positions before its first wait.
                    for (program.instructions) |instruction| {
                        if (instruction != .command) break;
                        switch (instruction.command) {
                            .animation, .highlight, .record_flags, .sound, .visible, .translucent, .reset_draw => {},
                            .shared_value => if (!target_signals) return error.InvalidUniteBindings,
                            .palette_cycle => if (schema_version < 24) return error.InvalidUniteBindings,
                            .effect => |effect| if (!target_signals or effect.binding != .shared or (!std.mem.eql(u8, effect.id, "blue_afterimages") and !(schema_version >= 24 and std.mem.eql(u8, effect.id, "palette_cycle")))) return error.InvalidUniteBindings,
                            .motion => |move| if (!signals or move.kind == .snap) return error.InvalidUniteBindings,
                            .offsets => |offset| if (!signals or offset.immediate) return error.InvalidUniteBindings,
                            else => return error.InvalidUniteBindings,
                        }
                    }
                }
            }
            if (unite.assist_after_damage and (!variants or unite.dispatch_after == null)) return error.InvalidUniteBindings;
            if (unite.dispatch_after) |after| if (!scheduled or after == 0 or after > 1000 or (unite.return_program == null and !unite.embedded_returns)) return error.InvalidUniteBindings;
            if (unite.record == 31 and unite.dispatch_after != null and schema_version >= 23) {
                if (unite.members.len != 2 or unite.controller != null or unite.transition != null or unite.damage_member != null or unite.damage_target_signal != null or unite.embedded_returns) return error.InvalidUniteBindings;
                for (unite.members) |member| if (member.loop_program == null or member.reaction_on_hit or member.deferred_entry or member.start_after != 0) return error.InvalidUniteBindings;
            }
            if (schema_version >= 27 and unite.record == 29 and unite.dispatch_after != null and unite.target_queue == null) return error.InvalidUniteBindings;
            if (unite.target_queue) |timing| {
                if (schema_version < 27 or unite.record != 29 or unite.members.len != 3 or unite.dispatch_after == null or unite.return_program == null or unite.controller != null or unite.transition != null or unite.damage_member != null or unite.damage_target_signal != null or unite.embedded_returns or unite.damage_reaction or unite.assist_after_damage or unite.impact_effect != null) return error.InvalidUniteBindings;
                _ = @import("battle_unite_queue.zig").State.init(timing, @splat(false)) catch return error.InvalidUniteBindings;
                for (unite.members) |member| if (member.loop_program == null or member.entry_program == null or member.reaction_on_hit or member.deferred_entry or member.start_after != 0 or member.fan != null) return error.InvalidUniteBindings;
            }
            for (unite.members, 0..) |member, ordinal| {
                if (member.hit_camera) |request| {
                    if (!target_signals or !member.reaction_on_hit or request.updates == 0 or request.updates > 1000) return error.InvalidUniteBindings;
                    _ = camera.ActorController.init(request.target) catch return error.InvalidUniteBindings;
                }
                if (member.deferred_entry) {
                    if (!deferred or member.start_after != 0 or member.fan != null) return error.InvalidUniteBindings;
                    const transition = unite.transition orelse return error.InvalidUniteBindings;
                    if (transition.trigger_member == ordinal or unite.members[transition.trigger_member].deferred_entry) return error.InvalidUniteBindings;
                    var dispatched = false;
                    for (transition.dispatches) |dispatch| if (dispatch.member == ordinal) {
                        dispatched = true;
                    };
                    if (!dispatched) return error.InvalidUniteBindings;
                }
                if (member.reaction_group and (!grouped or !member.reaction_on_hit)) return error.InvalidUniteBindings;
                if (member.reaction_variant > 3 or (member.reaction_variant > 0 and (!variants or !member.reaction_on_hit))) return error.InvalidUniteBindings;
                if (member.start_after > 0 and unite.dispatch_after == null and !(signals and unite.damage_signal != 2)) return error.InvalidUniteBindings;
                if (member.reaction_on_hit and unite.dispatch_after == null and (!grouped or unite.damage_member == null)) return error.InvalidUniteBindings;
                if (member.start_after > 1000 or @as(u32, unite.dispatch_after orelse 0) + member.start_after > 1000 or (unite.dispatch_after != null and member.programs.len != 1 and member.entry_program == null)) return error.InvalidUniteBindings;
                if (member.entry_program) |entry| {
                    if (!phased) return error.InvalidUniteBindings;
                    var listed = false;
                    for (member.programs) |id| listed = listed or std.mem.eql(u8, id, entry);
                    if (!listed) return error.InvalidUniteBindings;
                }
                if (member.loop_program) |loop| {
                    if (schema_version < 23 or !((unite.record == 31 and unite.members.len == 2) or (unite.record == 29 and unite.members.len == 3 and unite.target_queue != null)) or unite.dispatch_after == null or member.entry_program == null or unite.return_program == null) return error.InvalidUniteBindings;
                    var listed = false;
                    for (member.programs) |id| listed = listed or std.mem.eql(u8, id, loop);
                    if (!listed or std.mem.eql(u8, member.entry_program.?, loop)) return error.InvalidUniteBindings;
                }
                const resource = self.animations.find(member.id) orelse return error.MissingActorResource;
                if (member.fan) |fan| {
                    if (!fans or std.mem.eql(i16, &fan.node_angles, &.{ 0, 0, 0 }) or @popCount(fan.signal) != 1 or fan.velocity_q12 < -1048576 or fan.velocity_q12 > 1048576) return error.InvalidUniteBindings;
                    const clip = resource.find(fan.animation) orelse return error.MissingActorAnimation;
                    if (clip.frames.len != 1 or clip.semitransparent) return error.InvalidUniteBindings;
                }
                if (resource.find(0) == null or member.programs.len == 0 or member.programs.len > 8) return error.InvalidUniteBindings;
                for (unite.members[0..ordinal]) |prior| if (std.mem.eql(u8, prior.id, member.id)) return error.InvalidUniteBindings;
                for (member.programs, 0..) |id, choice| {
                    if (id.len <= member.id.len or !std.mem.startsWith(u8, id, member.id) or id[member.id.len] != '/') return error.InvalidUniteBindings;
                    for (member.programs[0..choice]) |prior| if (std.mem.eql(u8, prior, id)) return error.InvalidUniteBindings;
                    try self.validateProgram(resource, id);
                }
                if (unite.return_program) |id| try self.validateProgram(resource, id);
            }
        }
        for (self.programs.programs) |program| for (program.instructions) |instruction| {
            if (instruction == .command and instruction.command == .effect and std.mem.eql(u8, instruction.command.effect.id, "ivy_vine")) {
                const bindings = if (self.counter) |counter| counter.melee else null;
                const art = for ((bindings orelse return error.UnsupportedIvyComposition).enemies) |enemy| {
                    if (std.mem.eql(u8, enemy.attack_program, program.id)) break enemy.vine_art;
                } else null;
                if (schema_version < 30 or art == null or instruction.command.effect.binding != .self) return error.UnsupportedIvyComposition;
            }
            if (instruction == .command and instruction.command == .child) {
                const child = instruction.command.child;
                const resource = self.animations.find(child.resource) orelse return error.MissingActorResource;
                if (resource.find(child.animation) == null) return error.MissingActorAnimation;
                try self.validateProgram(resource, child.program);
            }
        };
    }
    fn validateProgram(self: Bundle, resource: Resource, id: []const u8) !void {
        const program = self.programs.find(id) orelse return error.MissingUniteProgram;
        for (program.instructions) |instruction| if (instruction == .command and instruction.command == .animation) {
            if (resource.find(instruction.command.animation) == null) return error.MissingActorAnimation;
        };
    }
};
pub fn loadBundle(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Bundle) {
    if (bytes.len > 16 * 1024 * 1024) return error.InvalidUniteBindings;
    const parsed = try std.json.parseFromSlice(Bundle, allocator, bytes, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const Runtime = struct {
    actors: []Actor,
    auxiliary: []?Actor = &.{},
    library: ?Library = null,
    origin_q12: [3]i32 = .{ 0, 0, 0 },
    camera_angles: [3]i16 = .{ 0, 0, 0 },
    camera_controller: ?*camera.ActorController = null,
    external: ?External = null,
    fn actor(self: *Runtime, id: u16) !*Actor {
        if (id < self.actors.len) return &self.actors[id];
        const slot = id - self.actors.len;
        if (slot >= self.auxiliary.len) return error.InvalidActorBinding;
        return if (self.auxiliary[slot]) |*value| value else error.InvalidActorBinding;
    }
    fn owner(self: *Runtime, id: u16) !*Actor {
        return self.actor((try self.actor(id)).owner orelse return error.MissingActorOwner);
    }
    pub fn dispatch(self: *Runtime, id: u16, owner_id: ?u16, program: vm.Program) !void {
        const current = try self.actor(id);
        if (current.resource == null) return error.MissingActorResource;
        if (owner_id) |index| _ = try self.actor(index);
        current.owner = owner_id;
        current.machine = vm.Machine.init(program, id);
        try current.machine.?.dispatch(self.host());
    }
    // The scene advances camera once before dispatching/updating actors.
    pub fn beginUpdate(self: *Runtime) void {
        if (self.camera_controller) |controller| controller.advance();
    }
    pub fn stepActor(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        if (current.resource == null) return;
        current.advanceAnimation();
        if (current.machine) |*machine| try machine.update(self.host());
        if (current.pending_tail_return) {
            current.pending_tail_return = false;
            const external = self.external orelse return error.MissingExternalHost;
            const tail = external.tail_return orelse return error.MissingExternalHost;
            try tail(external.context, id);
        }
        if (current.retired) {
            if (self.external) |external| if (external.release_actor) |release| try release(external.context, id);
            self.auxiliary[id - self.actors.len] = null;
            return;
        }
        if (current.movement) |*move| {
            for (0..2) |axis| {
                const difference = current.offset_destination[axis] - current.screen_offset[axis];
                current.screen_offset[axis] = @truncate(@as(i32, current.screen_offset[axis]) + @divTrunc(difference, move.remaining));
            }
            for (0..3) |axis| {
                current.position_q12[axis] +%= current.velocity_q12[axis];
                current.velocity_q12[axis] +%= current.acceleration_q12[axis];
            }
            move.remaining -= 1;
            if (move.remaining == 0) {
                current.position_q12 = move.destination;
                current.retained_destination_q12 = move.destination;
                for (0..2) |axis| current.screen_offset[axis] = @truncate(current.offset_destination[axis]);
                current.movement = null;
            }
        }
        if (current.suikomi_phase != null) try self.advanceSuikomi(id);
        if (current.ivy_vine) |*vine| {
            const target = try self.owner(id);
            if (try vine.advance(&current.shared_value, current.position_q12, target.home_q12) == .finished) current.ivy_vine = null;
        } else if (current.rabbit_return != null) {
            try self.advanceRabbitReturn(id);
        } else if (current.crow_dive != null) {
            try self.advanceCrowDive(id);
        } else if (current.projectile != null) {
            try self.advanceProjectile(id);
        } else if (current.blue_trail_active) {
            try self.advanceBlueTrail(id);
        } else if (current.shadow_fade != null) {
            try self.advanceShadowFade(id);
        } else if (current.mirage_worker != null) {
            try self.advanceMirageWorker(id);
        } else if (current.palette_cycle_active) {
            try current.advancePaletteCycle();
        } else if (current.reaction_callback) |kind| {
            switch (kind) {
                .airborne, .shadow_airborne => try self.advanceAirborne(id),
                .decoy => try self.advanceDecoy(id),
                .spin => switch (current.shared_value) {
                    1 => current.draw_angles[2] +%= 256,
                    2 => {
                        current.draw_angles[2] = 0;
                        current.reaction_callback = null;
                    },
                    else => {},
                },
                .camera_facing => {
                    const angles: [3]i32 = if (self.camera_controller) |controller| controller.sample().angles else .{ self.camera_angles[0], self.camera_angles[1], self.camera_angles[2] };
                    for (angles, 0..) |angle, axis| current.draw_angles[axis] = @truncate(angle);
                },
            }
        } else if (self.external) |external| if (external.after_actor) |advance| try advance(external.context, id);
    }
    fn advanceRabbitReturn(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        const returning = &current.rabbit_return.?;
        switch (current.shared_value) {
            1 => {
                for (0..3) |axis| returning.delta_q12[axis] = @divTrunc(current.home_q12[axis] -% current.position_q12[axis], 3);
                returning.hop = 1;
                current.shared_value = 2;
            },
            3 => {
                if (returning.hop == 0 or returning.hop > 3) return error.InvalidRabbitReturnState;
                const levels = [_]i32{ 0, 20 * 4096, -20 * 4096, 0 };
                var destination: [3]i32 = undefined;
                for (0..3) |axis| destination[axis] = current.position_q12[axis] +% returning.delta_q12[axis];
                destination[1] = destination[1] -% levels[returning.hop - 1] +% levels[returning.hop];
                current.velocity_q12 = .{ 0, 0, -12288 };
                for (0..3) |axis| current.acceleration_q12[axis] = @divTrunc(destination[axis] -% current.position_q12[axis] -% (current.velocity_q12[axis] *% 10), 45);
                current.movement = .{ .destination = destination, .remaining = 10 };
                returning.hop += 1;
                current.shared_value = 2;
            },
            4 => current.rabbit_return = null,
            else => {},
        }
    }
    fn advanceAirborne(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        switch (current.shared_value) {
            0 => {
                current.screen_offset[1] = @truncate((try current.attachment())[1]);
                current.draw_angles[1] = 2048;
                current.draw_angles[2] = 2048;
            },
            1, 3 => {
                const controller = self.camera_controller orelse return error.MissingActorCamera;
                const shake = if (current.reaction_callback == .shadow_airborne) blk: {
                    const regional = (try self.owner(id)).regional orelse return error.MissingRegionalBinding;
                    break :blk regional.camera_shake_z_q12;
                } else 20480;
                controller.velocity[0][2] = if (current.shared_value == 1) shake else -shake;
                controller.remaining[0] = 1;
                current.shared_value += 1;
            },
            2 => current.shared_value = 3,
            5, 7 => {
                const divisor: i32 = if (current.shared_value == 5) 3 else 2;
                var move = Movement{ .destination = undefined, .remaining = 20 };
                current.velocity_q12 = .{ 16384, 0, -12288 };
                for (0..3) |axis| {
                    move.destination[axis] = current.position_q12[axis] +% @divTrunc(current.home_q12[axis] -% current.position_q12[axis], divisor);
                    // This callback's helper sums n(n-1), unlike the ordinary jump helper.
                    current.acceleration_q12[axis] = @divTrunc(move.destination[axis] -% current.position_q12[axis] -% (current.velocity_q12[axis] *% 20), 380);
                }
                current.movement = move;
                current.shared_value += 1;
            },
            99 => {
                current.screen_offset = .{ 0, 0 };
                current.draw_angles[1] = 0;
                current.draw_angles[2] = 0;
                current.reaction_callback = null;
            },
            else => {},
        }
    }
    fn advanceDecoy(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        const target = try self.owner(id);
        switch (current.shared_value) {
            0 => {
                var destination = target.position_q12;
                destination[2] = @as(i32, (try target.attachment())[0]) * 4096;
                current.velocity_q12 = .{ 0, 0, -24576 };
                for (0..3) |axis| current.acceleration_q12[axis] = @divTrunc(destination[axis] -% current.position_q12[axis] -% (current.velocity_q12[axis] *% 20), 190);
                current.movement = .{ .destination = destination, .remaining = 20 };
                current.shared_value = 1;
            },
            1 => if (current.signals & 2 != 0) {
                const external = self.external orelse return error.MissingDecoyContact;
                const contact = external.decoy_contact orelse return error.MissingDecoyContact;
                const library = self.library orelse return error.MissingActorLibrary;
                const response = library.programs.find("common/decoy_response") orelse return error.MissingActorChildProgram;
                // The original HP writer rejects auxiliary targets, but its variance draw survives.
                try contact(external.context, current.owner.?, id);
                try self.dispatch(current.owner.?, id, response);
                current.reaction_callback = null;
            },
            else => {},
        }
    }
    fn advanceCrowDive(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        if (current.shared_value == 99) {
            current.crow_dive = null;
            return;
        }
        const dive = &current.crow_dive.?;
        if (current.shared_value == 0) {
            const target = try self.owner(id);
            dive.* = .{ .initialized = true, .points = .{
                current.position_q12,
                .{ target.position_q12[0], target.position_q12[1], 0 },
                .{ target.position_q12[0] *% 2 -% current.position_q12[0], target.position_q12[1], -100 * 4096 },
            } };
            current.shared_value = 1;
            return;
        }
        if (!dive.initialized) return error.MissingActorMotion;
        if (current.shared_value == 1 and dive.age >= 16) current.shared_value = 2;
        const age: i32 = dive.age;
        for (0..3) |axis| {
            const start = dive.points[0][axis];
            const control = dive.points[1][axis];
            const end = dive.points[2][axis];
            const curve = @divTrunc((start -% (control *% 2) +% end) *% age *% age, 900);
            const linear = @divTrunc((control -% start) *% (age *% 2), 30);
            current.position_q12[axis] = start +% curve +% linear;
        }
        dive.age +%= 1;
        if (dive.age >= 30) current.shared_value = 99;
    }
    fn advanceProjectile(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        const kind = current.projectile.?;
        if (kind == .rabbit_spin) {
            current.draw_angles[2] +%= 512;
            return;
        }
        switch (current.shared_value) {
            0 => {
                const attacker = try self.owner(id);
                const target = try self.actor(attacker.owner orelse return error.MissingActorOwner);
                const target_attachment = try target.attachment();
                for (0..2) |axis| current.offset_destination[axis] = target_attachment[axis];
                current.shared_value = 1;
            },
            1 => {
                if ((try self.owner(id)).signals & 2 != 0) current.shared_value = 2;
            },
            2 => {
                if ((try self.owner(id)).signals & 16 != 0) {
                    current.shared_value = 99;
                } else {
                    var move = Movement{ .destination = undefined, .remaining = 30 };
                    for (0..3) |axis| move.destination[axis] = current.position_q12[axis] +% (current.velocity_q12[axis] *% 30);
                    current.movement = move;
                    current.shared_value = 3;
                }
            },
            3 => {
                if (current.movement == null) current.shared_value = 99;
            },
            99 => {
                current.projectile = null;
                return;
            },
            else => {},
        }
        if (kind == .fixed) return;
        const angles: [3]i32 = if (self.camera_controller) |controller| controller.sample().angles else .{ self.camera_angles[0], self.camera_angles[1], self.camera_angles[2] };
        current.draw_angles[0] = @truncate(angles[0]);
        current.draw_angles[1] = @truncate(angles[1]);
        current.draw_angles[2] = if (kind == .aimed) @truncate(angles[2]) else current.draw_angles[2] +% 512;
    }
    fn advanceBlueTrail(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        if (current.blue_trail) |*trail| trail.visible = false;
        switch (current.shared_value) {
            0, 1 => {
                const external = self.external orelse return error.MissingActorProjection;
                const capture = external.previous_screen_position orelse return error.MissingActorProjection;
                const point = try capture(external.context, id);
                if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y) or !std.math.isFinite(point.depth)) return error.InvalidActorProjection;
                if (current.shared_value == 0) {
                    current.blue_trail = .{ .points = @splat(.{ point.x, point.y }), .depth = point.depth, .pose = current.resource.?.find(current.animation).?.frames[0].pose };
                    current.shared_value = 1;
                } else {
                    const trail = if (current.blue_trail) |*value| value else return error.InvalidBlueTrailState;
                    trail.points[trail.next] = .{ point.x, point.y };
                    trail.next +%= 1;
                    trail.depth = point.depth;
                    trail.visible = true;
                }
            },
            99 => current.shared_value = 100,
            100 => {
                current.blue_trail = null;
                current.blue_trail_active = false;
            },
            else => {},
        }
    }
    fn advanceSuikomi(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        const regional = (try self.owner(id)).regional orelse return error.MissingRegionalBinding;
        switch (current.suikomi_phase.?) {
            .shrink_spin => {
                current.draw_angles[1] = 1;
                current.draw_angles[0] +%= regional.shrink_spin_angle;
                current.draw_size_q12 = @max(0, current.draw_size_q12 - regional.shrink_step_q12);
                if (current.draw_size_q12 < regional.shrink_min_q12) current.suikomi_phase = null;
            },
            .spit_expand => {
                current.draw_size_q12 = @min(current.draw_size_q12 +| regional.expand_step_q12, regional.expand_target_q12);
                if (current.draw_size_q12 == regional.expand_target_q12) {
                    current.draw_angles[0] = 0;
                    current.draw_angles[1] = 0;
                    current.suikomi_phase = null;
                }
            },
        }
    }
    fn advanceShadowFade(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        const regional = current.regional orelse return error.MissingRegionalBinding;
        const fade = &current.shadow_fade.?;
        switch (current.shared_value) {
            0 => {
                for (current.position_q12, 0..) |coordinate, axis| fade.origin[axis] = coordinate >> 12;
                current.shared_value = 1;
            },
            1 => {
                fade.updates += 1;
                if (fade.updates >= regional.fade_updates) current.shared_value = 99;
            },
            99 => current.shared_value = 100,
            100 => current.shadow_fade = null,
            else => {},
        }
    }
    fn advanceMirageWorker(self: *Runtime, id: u16) !void {
        const current = try self.actor(id);
        const worker = &current.mirage_worker.?;
        switch (current.shared_value) {
            0 => {
                worker.origin_q12 = current.position_q12;
                switch (worker.kind) {
                    .fade => for (0..3) |axis| {
                        worker.delta_q12[axis] = current.home_q12[axis] -% current.position_q12[axis];
                    },
                    .vanish_left, .vanish_right => {
                        const target = try self.owner(id);
                        worker.delta_q12[0] = target.position_q12[0] +% worker.offset_q12 -% current.position_q12[0];
                        worker.delta_q12[1] = target.position_q12[1] -% current.position_q12[1];
                        worker.delta_q12[2] = target.position_q12[2] -% current.position_q12[2];
                    },
                }
                worker.timer = 0;
                current.shared_value = 1;
            },
            1 => {
                worker.timer +%= 1;
                if (worker.timer >= worker.phase_updates) {
                    for (0..3) |axis| current.position_q12[axis] +%= worker.delta_q12[axis];
                    current.shared_value = 2;
                }
            },
            2 => {
                worker.timer -|= 1;
                if (worker.timer == 0) current.shared_value = 99;
            },
            99 => current.shared_value = 100,
            100 => current.mirage_worker = null,
            else => {},
        }
    }
    pub fn spawn(self: *Runtime, parent_id: u16, child: vm.Child, draw_destination: ?[2]i16) !bool {
        const library = self.library orelse return error.MissingActorLibrary;
        const resource = library.resources.find(child.resource) orelse return error.MissingActorResource;
        const program = library.programs.find(child.program) orelse return error.MissingActorChildProgram;
        const parent = try self.actor(parent_id);
        const owner_id = if (child.owner == .self) parent_id else parent.owner orelse return error.MissingActorOwner;
        _ = try self.actor(owner_id);
        var position: [3]i32 = undefined;
        for (0..3) |axis| position[axis] = parent.position_q12[axis] +% (@as(i32, child.offset[axis]) * 4096);
        const home = if (child.home == .spawn) position else (try self.owner(parent_id)).position_q12;
        var index = self.auxiliary.len;
        while (index != 0) {
            index -= 1;
            if (self.auxiliary[index] != null) continue;
            const actor_id = std.math.cast(u16, self.actors.len + index) orelse return error.InvalidActorBinding;
            var instance = try Actor.initAnimation(resource, home, child.animation);
            instance.graphic_record = parent.graphic_record;
            instance.position_q12 = position;
            instance.has_draw_record = child.draw_record;
            if (draw_destination) |destination| {
                for (0..2) |axis| instance.offset_destination[axis] = destination[axis];
            }
            self.auxiliary[index] = instance;
            errdefer self.auxiliary[index] = null;
            try self.dispatch(actor_id, owner_id, program);
            return true;
        }
        return false;
    }
    pub fn requestCamera(self: *Runtime, id: u16, event: vm.Camera) !void {
        const current = try self.actor(id);
        const controller = self.camera_controller orelse return error.MissingActorCamera;
        const anchor: [3]i32 = switch (event.anchor) {
            .absolute => .{ 0, 0, 0 },
            .self => current.position_q12,
            .owner => (try self.owner(id)).position_q12,
        };
        try controller.request(.{ .at = 1, .updates = event.updates, .channel = switch (event.channel) {
            .focus => .focus,
            .angles => .angles,
            .translation => .translation,
            .scale => .scale,
        }, .binding = switch (event.anchor) {
            .absolute => .absolute,
            .self => .actor,
            .owner => .target,
        }, .target_q12 = event.value_q12 }, anchor);
    }
    fn host(self: *Runtime) vm.Host {
        return .{ .context = self, .command = command, .ready = ready };
    }
    fn command(context: *anyopaque, id: u16, request: vm.Command, resuming: bool) !bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        const current = try self.actor(id);
        switch (request) {
            .animation => |index| try current.selectAnimation(index),
            .color => |value| current.color = value,
            .visible => |value| current.visible = value,
            .translucent => |value| current.translucent = value,
            .reset_draw => |reset| current.palette = if (reset) .{ .resource = {} } else .{ .shared = 0 },
            .palette_cycle => |cycle| {
                if (cycle.updates == 0 or cycle.updates > 1000) return error.InvalidPaletteCycleConfig;
                for (cycle.variants) |variant| if (variant >= 7) return error.InvalidPaletteCycleConfig;
                if (current.palette_cycle_active) return error.PaletteCycleAlreadyActive;
                current.palette_cycle_config = cycle;
            },
            .effect => |effect| {
                if (current.ivy_vine != null) return error.ActorEffectAlreadyActive;
                if (current.crow_dive != null) return error.ActorEffectAlreadyActive;
                if (current.rabbit_return != null) return error.ActorEffectAlreadyActive;
                if (effect.binding == .shared and current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                if (effect.binding == .self and std.mem.eql(u8, effect.id, "camera_facing")) {
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                    current.reaction_callback = .camera_facing;
                } else if (effect.binding == .self and std.mem.eql(u8, effect.id, "rabbit_return")) {
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                    current.rabbit_return = .{};
                } else if (effect.binding == .self and std.mem.eql(u8, effect.id, "ivy_vine")) {
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                    _ = try self.owner(id);
                    current.ivy_vine = .{};
                } else if (effect.binding == .self and std.mem.eql(u8, effect.id, "crow_dive")) {
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                    _ = try self.owner(id);
                    current.crow_dive = .{};
                } else if (effect.binding == .self and std.mem.eql(u8, effect.id, "rabbit_projectile_spin")) {
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                    current.projectile = .rabbit_spin;
                } else if ((effect.binding == .shared and (std.mem.eql(u8, effect.id, "aimed_projectile") or std.mem.eql(u8, effect.id, "spinning_projectile"))) or (effect.binding == .self and std.mem.eql(u8, effect.id, "fixed_projectile"))) {
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active) return error.ActorEffectAlreadyActive;
                    _ = try self.owner(id);
                    current.projectile = if (std.mem.eql(u8, effect.id, "fixed_projectile")) .fixed else if (std.mem.eql(u8, effect.id, "aimed_projectile")) .aimed else .spinning;
                } else if (effect.binding == .shared and std.mem.eql(u8, effect.id, "blue_afterimages")) {
                    const external = self.external orelse return error.MissingActorProjection;
                    if (external.previous_screen_position == null) return error.MissingActorProjection;
                    if (current.projectile != null or current.palette_cycle_active or current.blue_trail_active) return error.ActorEffectAlreadyActive;
                    current.blue_trail_active = true;
                } else if (effect.binding == .shared and std.mem.eql(u8, effect.id, "palette_cycle")) {
                    if (current.palette_cycle_config == null) return error.MissingPaletteCycleConfig;
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active) return error.ActorEffectAlreadyActive;
                    current.palette_cycle_active = true;
                } else if (effect.binding == .owner and std.mem.eql(u8, effect.id, "recipient_spin")) {
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                    _ = try self.owner(id);
                    current.reaction_callback = .spin;
                } else if (effect.binding == .owner and std.mem.eql(u8, effect.id, "shadow_hurt")) {
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                    if (self.camera_controller == null) return error.MissingActorCamera;
                    if ((try self.owner(id)).regional == null) return error.MissingRegionalBinding;
                    current.reaction_callback = .shadow_airborne;
                } else if (effect.binding == .self and std.mem.eql(u8, effect.id, "shadow_fade")) {
                    if (current.shadow_fade != null or current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                    current.shadow_fade = .{};
                } else if (effect.binding == .self and (std.mem.eql(u8, effect.id, "mirage_vanish_left") or std.mem.eql(u8, effect.id, "mirage_fade") or std.mem.eql(u8, effect.id, "mirage_vanish_right"))) {
                    if (current.mirage_worker != null or current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
                    const regional = current.regional orelse return error.MissingRegionalBinding;
                    if (std.mem.eql(u8, effect.id, "mirage_vanish_left")) {
                        _ = try self.owner(id);
                        current.mirage_worker = .{ .kind = .vanish_left, .phase_updates = regional.vanish_phase_updates, .offset_q12 = -regional.vanish_offset_q12 };
                    } else if (std.mem.eql(u8, effect.id, "mirage_vanish_right")) {
                        _ = try self.owner(id);
                        current.mirage_worker = .{ .kind = .vanish_right, .phase_updates = regional.vanish_phase_updates, .offset_q12 = regional.vanish_offset_q12 };
                    } else {
                        current.mirage_worker = .{ .kind = .fade, .phase_updates = regional.vanish_phase_updates, .offset_q12 = 0 };
                    }
                } else if (effect.binding == .shared and (std.mem.eql(u8, effect.id, "airborne_recipient") or std.mem.eql(u8, effect.id, "decoy_retaliation"))) {
                    if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active) return error.ActorEffectAlreadyActive;
                    if (std.mem.eql(u8, effect.id, "airborne_recipient")) {
                        if (self.camera_controller == null) return error.MissingActorCamera;
                        current.reaction_callback = .airborne;
                    } else {
                        if (id < self.actors.len) return error.InvalidDecoyActor;
                        const target = try self.owner(id);
                        const external = self.external orelse return error.MissingDecoyContact;
                        if (external.decoy_contact == null) return error.MissingDecoyContact;
                        const library = self.library orelse return error.MissingActorLibrary;
                        if (library.programs.find("common/decoy_response") == null) return error.MissingActorChildProgram;
                        if (target.resource == null or target.resource.?.find(0) == null or target.resource.?.find(1) == null) return error.MissingActorResource;
                        current.reaction_callback = .decoy;
                    }
                } else {
                    const external = self.external orelse return error.UnsupportedActorCommand;
                    return external.command(external.context, id, request, resuming);
                }
            },
            .child => |child| return self.spawn(id, child, null),
            .teardown => {
                if (id < self.actors.len) return error.CannotTeardownParticipant;
                current.visible = false;
                current.retired = resuming;
                return resuming;
            },
            .camera => |event| {
                if (self.camera_controller == null) {
                    const external = self.external orelse return error.MissingActorCamera;
                    return external.command(external.context, id, request, resuming);
                }
                try self.requestCamera(id, event);
            },
            .resume_motion => |updates| {
                if (current.movement) |move| current.retained_destination_q12 = move.destination;
                if (updates > 0) {
                    // shortcut: initial source destinations are unqualified; require a prior move.
                    const destination = current.retained_destination_q12 orelse return error.MissingActorMotion;
                    current.movement = .{ .destination = destination, .remaining = @intCast(updates) };
                } else current.movement = null;
            },
            .motion => |motion| {
                if (motion.updates < (if (motion.kind != .jump) @as(u16, 1) else 2) or motion.updates > 1000 or (motion.kind == .snap and motion.updates != 1)) return error.InvalidActorMotion;
                const anchor = switch (motion.anchor) {
                    .absolute => self.origin_q12,
                    .self => current.position_q12,
                    .owner => (try self.owner(id)).position_q12,
                    .home => current.home_q12,
                };
                var move = Movement{ .destination = undefined, .remaining = motion.updates };
                current.velocity_q12 = motion.velocity_q12;
                const duration: i32 = motion.updates;
                const denominator = @divTrunc(duration * (duration - 1), 2);
                for (0..3) |axis| {
                    // Jumps anchor XY; linear moves anchor all three axes.
                    move.destination[axis] = (@as(i32, motion.offset[axis]) * 4096) +% (if (axis < 2 or motion.kind != .jump) anchor[axis] else 0);
                    if (motion.kind != .jump) {
                        current.velocity_q12[axis] = if (motion.kind == .snap) 0 else @divTrunc(move.destination[axis] -% current.position_q12[axis], duration);
                        current.acceleration_q12[axis] = 0;
                    } else {
                        const numerator = move.destination[axis] -% current.position_q12[axis] -% (current.velocity_q12[axis] *% duration);
                        current.acceleration_q12[axis] = @divTrunc(numerator, denominator);
                    }
                }
                current.movement = move;
            },
            .signal_set, .signal_clear => |mask| {
                const target = if (mask.target == .self) current else try self.owner(id);
                if (request == .signal_set) target.signals |= mask.bits else target.signals &= ~mask.bits;
            },
            .shared_value => |value| {
                if (!resuming) {
                    current.shared_value = value;
                    return false;
                }
            },
            .record_flags => |change| {
                if (change.set) current.record_flags |= change.bits else current.record_flags &= ~change.bits;
            },
            .highlight => |change| {
                const target = if (change.target == .self) current else try self.owner(id);
                if (change.set) target.highlights |= change.bits else target.highlights &= ~change.bits;
            },
            .release_actor => |released| current.released = released,
            .hold_coordinator_dispatch => {
                const external = self.external orelse return error.MissingExternalHost;
                const hold = external.hold_coordinator_dispatch orelse return error.MissingExternalHost;
                try hold(external.context, id);
            },
            .tail_return => {
                const external = self.external orelse return error.MissingExternalHost;
                if (external.tail_return == null) return error.MissingExternalHost;
                current.pending_tail_return = true;
            },
            .offsets => |change| {
                const relative = switch (change.anchor) {
                    .absolute => [2]i16{ 0, 0 },
                    .self => current.baseline_offset,
                    .owner => (try self.owner(id)).baseline_offset,
                };
                const attached = if (change.from_sprite) try (try self.owner(id)).attachment() else relative;
                for (0..2) |axis| {
                    current.offset_destination[axis] = @as(i32, attached[axis]) + change.value[axis];
                    if (change.immediate) {
                        current.screen_offset[axis] = @truncate(current.offset_destination[axis]);
                        current.offset_destination[axis] = current.screen_offset[axis];
                    }
                }
            },
            else => {
                const external = self.external orelse return error.UnsupportedActorCommand;
                return external.command(external.context, id, request, resuming);
            },
        }
        return true;
    }
    fn ready(context: *anyopaque, id: u16, condition: vm.Condition) !bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        const current = try self.actor(id);
        return switch (condition) {
            .animation_done => !current.animating,
            .movement_done => current.movement == null,
            .shared_value => |value| current.shared_value == value,
            .signal_set => |mask| (if (mask.target == .self) current else try self.owner(id)).signals & mask.bits != 0,
            .signal_clear => |mask| (if (mask.target == .self) current else try self.owner(id)).signals & mask.bits == 0,
            .highlight_clear => |mask| (if (mask.target == .self) current else try self.owner(id)).highlights & mask.bits == 0,
        };
    }
};
