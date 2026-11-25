const std = @import("std");
const host = @import("../battle_actor_host.zig");
const vm = @import("../battle_actor_program.zig");
const Runtime = @import("runtime.zig").Runtime;

pub fn activate(rt: *Runtime, id: u16, effect: vm.Effect, request: vm.Command, resuming: bool) !bool {
    const current = try rt.actor(id);
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
        _ = try rt.owner(id);
        current.ivy_vine = .{};
    } else if (effect.binding == .self and std.mem.eql(u8, effect.id, "crow_dive")) {
        if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
        _ = try rt.owner(id);
        current.crow_dive = .{};
    } else if (effect.binding == .self and std.mem.eql(u8, effect.id, "rabbit_projectile_spin")) {
        if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
        current.projectile = .rabbit_spin;
    } else if ((effect.binding == .shared and (std.mem.eql(u8, effect.id, "aimed_projectile") or std.mem.eql(u8, effect.id, "spinning_projectile"))) or (effect.binding == .self and std.mem.eql(u8, effect.id, "fixed_projectile"))) {
        if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active) return error.ActorEffectAlreadyActive;
        _ = try rt.owner(id);
        current.projectile = if (std.mem.eql(u8, effect.id, "fixed_projectile")) .fixed else if (std.mem.eql(u8, effect.id, "aimed_projectile")) .aimed else .spinning;
    } else if (effect.binding == .shared and std.mem.eql(u8, effect.id, "blue_afterimages")) {
        const external = rt.external orelse return error.MissingActorProjection;
        if (external.previous_screen_position == null) return error.MissingActorProjection;
        if (current.projectile != null or current.palette_cycle_active or current.blue_trail_active) return error.ActorEffectAlreadyActive;
        current.blue_trail_active = true;
    } else if (effect.binding == .shared and std.mem.eql(u8, effect.id, "palette_cycle")) {
        if (current.palette_cycle_config == null) return error.MissingPaletteCycleConfig;
        if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active) return error.ActorEffectAlreadyActive;
        current.palette_cycle_active = true;
    } else if (effect.binding == .owner and std.mem.eql(u8, effect.id, "recipient_spin")) {
        if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
        _ = try rt.owner(id);
        current.reaction_callback = .spin;
    } else if (effect.binding == .owner and std.mem.eql(u8, effect.id, "shadow_hurt")) {
        if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
        if (rt.camera_controller == null) return error.MissingActorCamera;
        if ((try rt.owner(id)).regional == null) return error.MissingRegionalBinding;
        current.reaction_callback = .shadow_airborne;
    } else if (effect.binding == .self and std.mem.eql(u8, effect.id, "shadow_fade")) {
        if (current.shadow_fade != null or current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
        current.shadow_fade = .{};
    } else if (effect.binding == .self and (std.mem.eql(u8, effect.id, "mirage_vanish_left") or std.mem.eql(u8, effect.id, "mirage_fade") or std.mem.eql(u8, effect.id, "mirage_vanish_right"))) {
        if (current.mirage_worker != null or current.projectile != null or current.blue_trail_active or current.palette_cycle_active or current.reaction_callback != null) return error.ActorEffectAlreadyActive;
        const regional = current.regional orelse return error.MissingRegionalBinding;
        if (std.mem.eql(u8, effect.id, "mirage_vanish_left")) {
            _ = try rt.owner(id);
            current.mirage_worker = .{ .kind = .vanish_left, .phase_updates = regional.vanish_phase_updates, .offset_q12 = -regional.vanish_offset_q12 };
        } else if (std.mem.eql(u8, effect.id, "mirage_vanish_right")) {
            _ = try rt.owner(id);
            current.mirage_worker = .{ .kind = .vanish_right, .phase_updates = regional.vanish_phase_updates, .offset_q12 = regional.vanish_offset_q12 };
        } else {
            current.mirage_worker = .{ .kind = .fade, .phase_updates = regional.vanish_phase_updates, .offset_q12 = 0 };
        }
    } else if (effect.binding == .shared and (std.mem.eql(u8, effect.id, "airborne_recipient") or std.mem.eql(u8, effect.id, "decoy_retaliation"))) {
        if (current.projectile != null or current.blue_trail_active or current.palette_cycle_active) return error.ActorEffectAlreadyActive;
        if (std.mem.eql(u8, effect.id, "airborne_recipient")) {
            if (rt.camera_controller == null) return error.MissingActorCamera;
            current.reaction_callback = .airborne;
        } else {
            if (id < rt.actors.len) return error.InvalidDecoyActor;
            const target = try rt.owner(id);
            const external = rt.external orelse return error.MissingDecoyContact;
            if (external.decoy_contact == null) return error.MissingDecoyContact;
            const library = rt.library orelse return error.MissingActorLibrary;
            if (library.programs.find("common/decoy_response") == null) return error.MissingActorChildProgram;
            if (target.resource == null or target.resource.?.find(0) == null or target.resource.?.find(1) == null) return error.MissingActorResource;
            current.reaction_callback = .decoy;
        }
    } else {
        const external = rt.external orelse return error.UnsupportedActorCommand;
        return external.command(external.context, id, request, resuming);
    }
    return true;
}

pub fn advanceRabbitReturn(rt: *Runtime, id: u16) !void {
    const current = try rt.actor(id);
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

pub fn advanceAirborne(rt: *Runtime, id: u16) !void {
    const current = try rt.actor(id);
    switch (current.shared_value) {
        0 => {
            current.screen_offset[1] = @truncate((try current.attachment())[1]);
            current.draw_angles[1] = 2048;
            current.draw_angles[2] = 2048;
        },
        1, 3 => {
            const controller = rt.camera_controller orelse return error.MissingActorCamera;
            const shake = if (current.reaction_callback == .shadow_airborne) blk: {
                const regional = (try rt.owner(id)).regional orelse return error.MissingRegionalBinding;
                break :blk regional.camera_shake_z_q12;
            } else 20480;
            controller.velocity[0][2] = if (current.shared_value == 1) shake else -shake;
            controller.remaining[0] = 1;
            current.shared_value += 1;
        },
        2 => current.shared_value = 3,
        5, 7 => {
            const divisor: i32 = if (current.shared_value == 5) 3 else 2;
            var move = host.Movement{ .destination = undefined, .remaining = 20 };
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

pub fn advanceDecoy(rt: *Runtime, id: u16) !void {
    const current = try rt.actor(id);
    const target = try rt.owner(id);
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
            const external = rt.external orelse return error.MissingDecoyContact;
            const contact = external.decoy_contact orelse return error.MissingDecoyContact;
            const library = rt.library orelse return error.MissingActorLibrary;
            const response = library.programs.find("common/decoy_response") orelse return error.MissingActorChildProgram;
            // The original HP writer rejects auxiliary targets, but its variance draw survives.
            try contact(external.context, current.owner.?, id);
            try rt.dispatch(current.owner.?, id, response);
            current.reaction_callback = null;
        },
        else => {},
    }
}

pub fn advanceCrowDive(rt: *Runtime, id: u16) !void {
    const current = try rt.actor(id);
    if (current.shared_value == 99) {
        current.crow_dive = null;
        return;
    }
    const dive = &current.crow_dive.?;
    if (current.shared_value == 0) {
        const target = try rt.owner(id);
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

pub fn advanceProjectile(rt: *Runtime, id: u16) !void {
    const current = try rt.actor(id);
    const kind = current.projectile.?;
    if (kind == .rabbit_spin) {
        current.draw_angles[2] +%= 512;
        return;
    }
    switch (current.shared_value) {
        0 => {
            const attacker = try rt.owner(id);
            const target = try rt.actor(attacker.owner orelse return error.MissingActorOwner);
            const target_attachment = try target.attachment();
            for (0..2) |axis| current.offset_destination[axis] = target_attachment[axis];
            current.shared_value = 1;
        },
        1 => {
            if ((try rt.owner(id)).signals & 2 != 0) current.shared_value = 2;
        },
        2 => {
            if ((try rt.owner(id)).signals & 16 != 0) {
                current.shared_value = 99;
            } else {
                var move = host.Movement{ .destination = undefined, .remaining = 30 };
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
    const angles: [3]i32 = if (rt.camera_controller) |controller| controller.sample().angles else .{ rt.camera_angles[0], rt.camera_angles[1], rt.camera_angles[2] };
    current.draw_angles[0] = @truncate(angles[0]);
    current.draw_angles[1] = @truncate(angles[1]);
    current.draw_angles[2] = if (kind == .aimed) @truncate(angles[2]) else current.draw_angles[2] +% 512;
}

pub fn advanceBlueTrail(rt: *Runtime, id: u16) !void {
    const current = try rt.actor(id);
    if (current.blue_trail) |*trail| trail.visible = false;
    switch (current.shared_value) {
        0, 1 => {
            const external = rt.external orelse return error.MissingActorProjection;
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

pub fn advanceSuikomi(rt: *Runtime, id: u16) !void {
    const current = try rt.actor(id);
    const regional = (try rt.owner(id)).regional orelse return error.MissingRegionalBinding;
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

pub fn advanceShadowFade(rt: *Runtime, id: u16) !void {
    const current = try rt.actor(id);
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

pub fn advanceMirageWorker(rt: *Runtime, id: u16) !void {
    const current = try rt.actor(id);
    const worker = &current.mirage_worker.?;
    switch (current.shared_value) {
        0 => {
            worker.origin_q12 = current.position_q12;
            switch (worker.kind) {
                .fade => for (0..3) |axis| {
                    worker.delta_q12[axis] = current.home_q12[axis] -% current.position_q12[axis];
                },
                .vanish_left, .vanish_right => {
                    const target = try rt.owner(id);
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
