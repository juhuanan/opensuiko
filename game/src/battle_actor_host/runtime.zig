const std = @import("std");
const actor_host = @import("../battle_actor_host.zig");
const vm = @import("../battle_actor_program.zig");
const camera = @import("battle_camera");
const effects = @import("effects.zig");

pub const Runtime = struct {
    actors: []actor_host.Actor,
    auxiliary: []?actor_host.Actor = &.{},
    library: ?actor_host.Library = null,
    origin_q12: [3]i32 = .{ 0, 0, 0 },
    camera_angles: [3]i16 = .{ 0, 0, 0 },
    camera_controller: ?*camera.ActorController = null,
    external: ?actor_host.External = null,

    pub fn actor(self: *Runtime, id: u16) !*actor_host.Actor {
        if (id < self.actors.len) return &self.actors[id];
        const slot = id - self.actors.len;
        if (slot >= self.auxiliary.len) return error.InvalidActorBinding;
        return if (self.auxiliary[slot]) |*value| value else error.InvalidActorBinding;
    }

    pub fn owner(self: *Runtime, id: u16) !*actor_host.Actor {
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
        if (current.suikomi_phase != null) try effects.advanceSuikomi(self, id);
        if (current.ivy_vine) |*vine| {
            const target = try self.owner(id);
            if (try vine.advance(&current.shared_value, current.position_q12, target.home_q12) == .finished) current.ivy_vine = null;
        } else if (current.rabbit_return != null) {
            try effects.advanceRabbitReturn(self, id);
        } else if (current.crow_dive != null) {
            try effects.advanceCrowDive(self, id);
        } else if (current.projectile != null) {
            try effects.advanceProjectile(self, id);
        } else if (current.blue_trail_active) {
            try effects.advanceBlueTrail(self, id);
        } else if (current.shadow_fade != null) {
            try effects.advanceShadowFade(self, id);
        } else if (current.mirage_worker != null) {
            try effects.advanceMirageWorker(self, id);
        } else if (current.palette_cycle_active) {
            try current.advancePaletteCycle();
        } else if (current.reaction_callback) |kind| {
            switch (kind) {
                .airborne, .shadow_airborne => try effects.advanceAirborne(self, id),
                .decoy => try effects.advanceDecoy(self, id),
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

    pub fn spawn(self: *Runtime, parent_id: u16, child: vm.Child, draw_destination: ?[2]i16) !bool {
        const library = self.library orelse return error.MissingActorLibrary;
        const resource = library.resources.find(child.resource) orelse return error.MissingActorResource;
        const program = library.programs.find(child.program) orelse return error.MissingActorChildProgram;
        const parent = try self.actor(parent_id);
        const owner_id = if (child.owner == .self) parent_id else parent.owner orelse return error.MissingActorOwner;
        _ = try self.actor(owner_id);
        var position: [3]i32 = undefined;
        for (0..3) |axis| position[axis] = parent.position_q12[axis] +% camera.FixedQ12.fromInt(child.offset[axis]).raw;
        const home = if (child.home == .spawn) position else (try self.owner(parent_id)).position_q12;
        var index = self.auxiliary.len;
        while (index != 0) {
            index -= 1;
            if (self.auxiliary[index] != null) continue;
            const actor_id = std.math.cast(u16, self.actors.len + index) orelse return error.InvalidActorBinding;
            var instance = try actor_host.Actor.initAnimation(resource, home, child.animation);
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
        try controller.request(.{
            .at = 1,
            .updates = event.updates,
            .channel = switch (event.channel) {
                .focus => .focus,
                .angles => .angles,
                .translation => .translation,
                .scale => .scale,
            },
            .binding = switch (event.anchor) {
                .absolute => .absolute,
                .self => .actor,
                .owner => .target,
            },
            .target_q12 = event.value_q12,
        }, anchor);
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
            .effect => |effect| return effects.activate(self, id, effect, request, resuming),
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
                var move = actor_host.Movement{ .destination = undefined, .remaining = motion.updates };
                current.velocity_q12 = motion.velocity_q12;
                const duration: i32 = motion.updates;
                const denominator = @divTrunc(duration * (duration - 1), 2);
                for (0..3) |axis| {
                    // Jumps anchor XY; linear moves anchor all three axes.
                    move.destination[axis] = camera.FixedQ12.fromInt(motion.offset[axis]).raw +% (if (axis < 2 or motion.kind != .jump) anchor[axis] else 0);
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
