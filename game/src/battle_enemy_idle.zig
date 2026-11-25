//! Idle playback shares the body and motion, but never owns action completion.
const std = @import("std");
const battle = @import("battle.zig");
const host = @import("battle_actor_host.zig");
const vm = @import("battle_actor_program.zig");
const layout = @import("battle_layout.zig");
const State = battle.State;
pub const program_id = "melee/holly_fairy/idle";

pub const Playback = struct {
    machine: ?vm.Machine = null,
    updated_at: ?u32 = null,
};

pub fn hasSourceEnemyIdle(self: *const State, actor: usize) bool {
    if (actor < self.partyCount() or actor >= self.partyCount() + self.enemyCount()) return false;
    const bundle = self.unite_actors orelse return false;
    return self.enemy(actor - self.partyCount()).action_policy == .source_holly_fairy and bundle.programs.find(program_id) != null;
}

fn q12(point: battle.Position) [3]i32 {
    return .{ @intFromFloat(@round(point.x * 4096)), @intFromFloat(@round(point.y * 4096)), @intFromFloat(@round(point.z * 4096)) };
}

pub fn prepareActor(self: *State, actor: usize, resource: host.Resource, position: [3]i32) !host.Actor {
    var result = try host.Actor.init(resource, q12(self.uniteVmHome(actor)));
    result.position_q12 = position;
    result.screen_offset = self.actor_screen_offsets[actor];
    const profile = if (actor < self.partyCount()) self.partyProfile(actor) else self.enemy(actor - self.partyCount());
    result.baseline_offset = profile.effect_offset orelse .{ 0, 0 };
    if (self.unite_vm.idle[actor] != null) {
        const previous = self.unite_vm.actors[actor];
        result.position_q12 = previous.position_q12;
        result.movement = previous.movement;
        result.retained_destination_q12 = previous.retained_destination_q12;
        result.velocity_q12 = previous.velocity_q12;
        result.acceleration_q12 = previous.acceleration_q12;
        result.offset_destination = previous.offset_destination;
        result.screen_offset = previous.screen_offset;
    }
    return result;
}

fn followReaction(self: *State, actor: usize, current: *host.Actor) !bool {
    var reacting = self.spellReaction(actor) != null;
    if (self.uniteReactionProgram(actor)) |reaction| {
        const instance = self.unite_reactions[actor].?;
        const age = self.camera_ticks - instance.started_at;
        if (age <= reaction.duration) {
            reacting = reacting or age < reaction.duration;
            if (reaction.motions.len != 0 and age >= reaction.motions[0].at) {
                current.position_q12 = battle.spell_scene.unitePosition(reaction, instance.origin_q12, instance.home_q12, age);
                current.movement = null;
            }
        }
    }
    if (self.hasSpellScene()) {
        const instance = &self.active.?.scene.?;
        const program = instance.sceneProgram(self.spell_scenes.?);
        if (program.actor_motion) |motion| {
            const age = self.effectTicks();
            if (age >= motion.start and age <= motion.returning + motion.updates) {
                for (instance.targets[0..instance.target_count]) |target| {
                    if (target.actor != actor or !target.movable) continue;
                    if (try battle.spell_scene.actorTransform(program, target, age)) |sample| {
                        current.position_q12 = sample.position;
                        current.movement = null;
                        reacting = reacting or age < motion.returning + motion.updates;
                    }
                }
            }
        }
    }
    return reacting;
}

pub fn stepEnemyIdleActor(self: *State, runtime: *host.Runtime, actor: u16) !void {
    if (!self.hasSourceEnemyIdle(actor)) return runtime.stepActor(actor);
    const bundle = self.unite_actors.?;
    const owned = self.unite_vm.ownsActor(actor);
    if (self.unite_vm.idle[actor] == null) {
        if (!self.participates(actor)) return runtime.stepActor(actor);
        if (!owned) {
            const resource = bundle.animations.find("holly_fairy") orelse return error.MissingActorResource;
            const position = q12(layout.worldPosition(self, actor));
            runtime.actors[actor] = try host.Actor.init(resource, q12(self.uniteVmHome(actor)));
            runtime.actors[actor].position_q12 = position;
            runtime.actors[actor].screen_offset = self.actor_screen_offsets[actor];
            runtime.actors[actor].baseline_offset = self.enemy(actor - self.partyCount()).effect_offset orelse .{ 0, 0 };
        }
        self.unite_vm.idle[actor] = .{};
    }
    const idle = &self.unite_vm.idle[actor].?;
    if (idle.updated_at == self.camera_ticks) return;
    idle.updated_at = self.camera_ticks;
    const current = &runtime.actors[actor];
    if (!owned) current.machine = null;
    // External reaction tracks replace the idle script while its pending motion continues.
    const reacting = !owned and try followReaction(self, actor, current);
    if (reacting) idle.machine = null;
    if (idle.machine != null and (current.machine == null or current.machine.?.halted)) {
        const action_machine = current.machine;
        current.machine = idle.machine;
        defer current.machine = action_machine;
        try runtime.stepActor(actor);
        idle.machine = current.machine;
    } else {
        idle.machine = null;
        try runtime.stepActor(actor);
    }
    if (!self.participates(actor)) {
        idle.machine = null;
        if (!owned) {
            @import("battle_counter_host.zig").retainPosition(self, actor);
            self.unite_vm.idle[actor] = null;
        }
        return;
    }
    if (!reacting and (current.machine == null or current.machine.?.halted) and (idle.machine == null or idle.machine.?.halted)) {
        const action_machine = current.machine;
        defer current.machine = action_machine;
        try runtime.dispatch(actor, actor, bundle.programs.find(program_id).?);
        idle.machine = current.machine;
    }
}

pub fn advanceEnemyIdle(self: *State) void {
    if (self.camera_ticks == 0 or self.unite_actors == null or self.replay_exhausted or self.replay_unsupported != null) return;
    var runtime = host.Runtime{ .actors = &self.unite_vm.actors, .library = self.unite_actors.?.library() };
    for (self.partyCount()..self.partyCount() + self.enemyCount()) |actor| {
        if (!self.hasSourceEnemyIdle(actor) or self.unite_vm.ownsActor(actor)) continue;
        self.stepEnemyIdleActor(&runtime, @intCast(actor)) catch {
            self.replay_unsupported = .coordinator_action;
            return;
        };
    }
}

pub fn rebind(playback: *battle.unite_playback.State, bundle: *const host.Bundle) !void {
    for (&playback.idle, 0..) |*maybe, actor| if (maybe.*) |*idle| {
        const resource = bundle.animations.find("holly_fairy") orelse return error.InvalidActorPlayback;
        const program = bundle.programs.find(program_id) orelse return error.InvalidActorPlayback;
        const current = &playback.actors[actor];
        if (!playback.ownsActor(actor)) {
            if (current.machine != null and !current.machine.?.halted) return error.InvalidActorPlayback;
            current.machine = null;
        }
        if (current.resource == null or !std.mem.eql(u8, current.resource.?.id, resource.id)) return error.InvalidActorPlayback;
        const clip = resource.find(current.animation) orelse return error.InvalidActorPlayback;
        if (current.frame >= clip.frames.len or (current.animating and current.frame_remaining == 0)) return error.InvalidActorPlayback;
        current.resource = resource;
        if (idle.machine) |*machine| {
            if (machine.actor != actor or machine.pc >= program.instructions.len) return error.InvalidActorPlayback;
            machine.instructions = program.instructions;
        }
    };
}
