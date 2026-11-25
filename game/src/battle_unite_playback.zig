//! Live member programs; gameplay owns damage, locks, camera and status rules.
const std = @import("std");
const host = @import("battle_actor_host.zig");
const vm = @import("battle_actor_program.zig");
const camera = @import("battle_camera");
const physical = @import("battle_physical.zig");
const counter = @import("battle_counter.zig");
const Point = @import("battle_presentation.zig").ScreenPoint;
const CombatState = @import("battle.zig").State;

pub const Fan = struct { visible: bool = false, finished: bool = false, local_x_q12: i32 = 0, anchor: [3]i32 = .{ 0, 0, 0 } };
pub const Member = struct {
    fan: ?Fan = null,
    record: u8,
    leader: u8,
    target: u8,
    resource: u8,
    program: u16,
    return_program: ?u16,
    pending_dispatch: bool = false,
    deferred_entry: bool = false,
    start_at: u32,
    age: u16 = 0,
    initialized: bool = false,
    returning: bool = false,
    recovery_applied: bool = false,
    reaction_on_hit: bool = false,
    reaction_variant: u8 = 0,
    reaction_group: bool = false,
};
// Combatants and children share 19 available actor slots.
const actor_capacity = 19;
const AuxiliaryBinding = struct { resource: u8, program: u16 };
pub const Sound = struct { actor: u8 = 0, id: u16 = 0 };
const RuntimeContext = struct {
    state: *CombatState,
    playback: *State,
    initial_camera: camera.Block,
    runtime: *host.Runtime = undefined,
    fn command(raw: *anyopaque, actor: u16, request: vm.Command, _: bool) !bool {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        switch (request) {
            .sound => |id| try ctx.playback.emitSound(ctx.state.camera_ticks, @intCast(actor), id),
            .recovery => |boundaries| {
                if (!ctx.playback.ownsActor(actor) or actor >= ctx.state.partyCount()) return error.InvalidActorRecovery;
                try ctx.state.requestUniteRecovery(actor, boundaries);
                if (ctx.playback.members[actor]) |*member| member.recovery_applied = true;
            },
            .status => |attempt| {
                if (!ctx.playback.ownsActor(actor)) return error.InvalidActorStatus;
                try ctx.state.requestActorStatus(actor, attempt);
            },
            .camera => |event| {
                if (ctx.state.actor_camera == null) ctx.state.actor_camera = try camera.ActorController.init(ctx.initial_camera);
                ctx.runtime.camera_controller = &ctx.state.actor_camera.?;
                try ctx.runtime.requestCamera(actor, event);
            },
            .effect => |effect| {
                if (effect.binding == .self and std.mem.eql(u8, effect.id, "ally_throw")) {
                    try ctx.state.beginStrongArmCooperation(actor);
                    return true;
                }
                if (effect.binding != .self or (!std.mem.eql(u8, effect.id, "kobold_magic") and !std.mem.eql(u8, effect.id, "enemy_group_magic"))) return error.UnsupportedUniteActorCommand;
                try ctx.state.beginEnemyMagicEffect(actor);
            },
            else => return error.UnsupportedUniteActorCommand,
        }
        return true;
    }
    fn after(raw: *anyopaque, actor: u16) !void {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        try ctx.state.advanceEnemyMagicActor(actor, ctx.runtime);
        ctx.state.advanceCoverActor(actor);
        try ctx.state.advanceStrongArmActor(actor, ctx.runtime);
        ctx.state.releaseProjectileTurn(actor, ctx.runtime);
        ctx.state.syncRegionalActorVisuals(actor, ctx.runtime);
    }
    fn previous(raw: *anyopaque, actor: u16) !Point {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        if (actor >= ctx.playback.previous_points.len) return error.InvalidActorBinding;
        return ctx.playback.previous_points[actor];
    }
    fn decoy(raw: *anyopaque, attacker: u16, child: u16) !void {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        if (attacker >= ctx.playback.actors.len or child < ctx.playback.actors.len or child - ctx.playback.actors.len >= ctx.playback.auxiliary_capacity) return error.InvalidActorBinding;
        _ = ctx.state.roll();
        if (ctx.state.replay_exhausted) return error.RandomInputExhausted;
    }
    fn holdCoordinatorDispatch(raw: *anyopaque, actor: u16) !void {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        try ctx.state.holdRegionalDispatch(actor);
    }
    fn tailReturn(raw: *anyopaque, actor: u16) !void {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        try ctx.state.dispatchPartyTailReturn(actor, ctx.runtime);
    }
};
pub const State = struct {
    actors: [12]host.Actor = @splat(host.Actor.anchor(.{ 0, 0, 0 }, .{ 0, 0, 0 }, null)),
    auxiliary: [actor_capacity]?host.Actor = @splat(null),
    auxiliary_bindings: [actor_capacity]?AuxiliaryBinding = @splat(null),
    auxiliary_capacity: u5 = 0,
    members: [6]?Member = @splat(null),
    physical_actions: [6]?physical.Playback = @splat(null),
    counter_actions: [12]?counter.Playback = @splat(null),
    enemy_magic_actions: [12]?@import("battle_enemy_magic.zig").Playback = @splat(null),
    commander_actions: [12]?@import("battle_commander.zig").Playback = @splat(null),
    wave_actions: [12]?@import("battle_enemy_wave.zig").Playback = @splat(null),
    idle: [12]?@import("battle_enemy_idle.zig").Playback = @splat(null),
    scripted_actors: [12]?host.ParticipantBinding = @splat(null),
    physical_logic_at: ?u32 = null,
    callback_sounds_at: ?u32 = null, // Shared cue frame for every producer.
    previous_points: [12 + actor_capacity]Point = @splat(.{ .x = 0, .y = 0, .depth = 1 }),
    impact_at: [6]?u16 = @splat(null),
    prepare_at: [6]?u32 = @splat(null),
    sounds: [16]Sound = @splat(.{}),
    sound_count: u5 = 0,

    pub fn jsonStringify(self: State, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(State).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "commander_actions")) self.hasCommander() else if (comptime std.mem.eql(u8, name, "wave_actions")) self.hasEnemyWave() else if (comptime std.mem.eql(u8, name, "idle")) self.hasIdle() else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }

    pub fn takeSounds(self: *State) []const Sound {
        const count = self.sound_count;
        self.sound_count = 0;
        return self.sounds[0..count];
    }

    pub fn beginSoundFrame(self: *State, tick: u32) void {
        if (self.callback_sounds_at == tick) return;
        self.callback_sounds_at = tick;
        self.sound_count = 0;
    }

    pub fn emitSound(self: *State, tick: u32, actor: u8, id: u16) !void {
        self.beginSoundFrame(tick);
        if (self.sound_count >= self.sounds.len) return error.ActorSoundOverflow;
        self.sounds[self.sound_count] = .{ .actor = actor, .id = id };
        self.sound_count += 1;
    }

    pub fn hasIdle(self: State) bool {
        for (self.idle) |entry| if (entry != null) return true;
        return false;
    }
    pub fn hasActors(self: State) bool {
        for (self.members) |member| if (member != null) return true;
        if (self.hasPhysical()) return true;
        if (self.hasCounter()) return true;
        if (self.hasEnemyMagic()) return true;
        if (self.hasCommander()) return true;
        if (self.hasEnemyWave()) return true;
        return self.hasAuxiliary();
    }
    pub fn hasPhysical(self: State) bool {
        for (self.physical_actions) |action| if (action != null) return true;
        return false;
    }
    pub fn hasCounter(self: State) bool {
        for (self.counter_actions) |action| if (action != null) return true;
        return false;
    }
    pub fn hasEnemyMagic(self: State) bool {
        for (self.enemy_magic_actions) |action| if (action != null) return true;
        return false;
    }
    pub fn hasCommander(self: State) bool {
        for (self.commander_actions) |action| if (action != null) return true;
        return false;
    }
    pub fn hasEnemyWave(self: State) bool {
        for (self.wave_actions) |action| if (action != null) return true;
        return false;
    }
    pub fn ownsActor(self: *const State, actor: usize) bool {
        return self.owns(actor) or (actor < self.scripted_actors.len and self.scripted_actors[actor] != null);
    }
    pub fn hasAuxiliary(self: State) bool {
        for (self.auxiliary) |child| if (child != null) return true;
        return false;
    }
    pub fn owns(self: *const State, actor: usize) bool {
        return actor < self.members.len and self.members[actor] != null;
    }
    pub fn hitReady(self: State, actor: usize) bool {
        return self.signalReady(actor, 2);
    }
    pub fn signalReady(self: State, actor: usize, signal: u16) bool {
        return self.owns(actor) and self.members[actor].?.initialized and self.actors[actor].signals & signal != 0;
    }
    pub fn allReady(self: State, leader: usize) bool {
        var found = false;
        for (self.members, 0..) |maybe, actor| if (maybe) |member| {
            if (member.leader != leader) continue;
            found = true;
            if (!member.initialized) return false;
            if (!member.returning and self.actors[actor].signals & 4 == 0) return false;
        };
        return found;
    }
    pub fn pose(self: *const State, actor: usize) ?u16 {
        if (actor < self.scripted_actors.len and (self.scripted_actors[actor] != null or self.idle[actor] != null)) return self.actors[actor].currentFrame().pose;
        if (!self.owns(actor) or !self.members[actor].?.initialized) return null;
        return self.actors[actor].currentFrame().pose;
    }
    pub fn position(self: *const State, actor: usize) ?[3]i32 {
        return if (self.pose(actor) != null) self.actors[actor].position_q12 else null;
    }
    fn programIndex(bundle: *const host.Bundle, id: []const u8) !u16 {
        for (bundle.programs.programs, 0..) |program, index| if (std.mem.eql(u8, id, program.id)) return @intCast(index);
        return error.MissingUniteProgram;
    }
    pub fn begin(self: *State, bundle: *const host.Bundle, record: u8, leader: u8, target: u8, party: []const []const u8, homes: []const [3]i32, selected_at: u32) !void {
        const binding = bundle.find(record) orelse return error.InvalidUniteBindings;
        if (party.len == 0 or party.len > self.members.len or leader >= party.len or target < party.len or target >= homes.len or homes.len > self.actors.len) return error.InvalidActorBinding;
        const returning = if (binding.return_program) |id| try programIndex(bundle, id) else if (binding.embedded_returns) null else return error.MissingUniteProgram;
        const dispatch_after = binding.dispatch_after orelse if (record <= 1) @as(u16, 1) else return error.UnsupportedUniteProgramSelection;
        var next = self.*;
        next.auxiliary_capacity = @intCast(actor_capacity - homes.len);
        for (next.auxiliary[next.auxiliary_capacity..]) |child| if (child != null) return error.ActorAlreadyOwned;
        var found_leader = false;
        for (binding.members) |member| {
            const entry = member.entry_program orelse if (member.programs.len == 1) member.programs[0] else return error.UnsupportedUniteProgramSelection;
            const slot = for (party, 0..) |id, index| {
                if (std.mem.eql(u8, member.id, id)) break index;
            } else return error.MissingUniteParticipant;
            if (next.ownsActor(slot)) return error.ActorAlreadyOwned;
            const resource_index = for (bundle.animations.resources, 0..) |resource, index| {
                if (std.mem.eql(u8, resource.id, member.id)) break index;
            } else return error.MissingActorResource;
            next.actors[slot] = try host.Actor.init(bundle.animations.resources[resource_index], homes[slot]);
            if (binding.beat_child != null or binding.wave_heights != null) next.actors[slot].graphic_record = record;
            next.members[slot] = .{ .record = record, .leader = leader, .target = target, .resource = @intCast(resource_index), .program = try programIndex(bundle, entry), .return_program = returning, .deferred_entry = member.deferred_entry, .start_at = selected_at +% dispatch_after +% member.start_after, .reaction_on_hit = member.reaction_on_hit, .reaction_variant = member.reaction_variant, .reaction_group = member.reaction_group, .fan = if (member.fan != null) .{} else null };
            found_leader = found_leader or slot == leader;
        }
        if (!found_leader) return error.InvalidActorBinding;
        next.impact_at[leader] = null;
        next.prepare_at[leader] = selected_at +% 1;
        self.* = next;
    }
    // Checkpoint state contains indices so matching content can have a different arena owner.
    pub fn rebind(self: *State, bundle: *const host.Bundle) !void {
        try @import("battle_enemy_idle.zig").rebind(self, bundle);
        for (self.wave_actions, 0..) |maybe, owner| if (maybe) |playback| {
            if (bundle.enemy_wave == null or playback.owner != owner) return error.InvalidActorPlayback;
            if (playback.action) |action| {
                if (action.owner != owner or action.completed != (playback.completed_at != null)) return error.InvalidActorPlayback;
            } else if (playback.completed_at != null) return error.InvalidActorPlayback;
        };
        for (self.commander_actions, 0..) |maybe, owner| if (maybe) |playback| {
            const order = bundle.commanderFor(playback.id) orelse return error.InvalidActorPlayback;
            if (playback.owner != owner or (playback.recipient != null and (order.solo_program == null or playback.recipient.? >= self.actors.len or playback.recipient.? == owner))) return error.InvalidActorPlayback;
            if (playback.action) |action| if (action.owner != owner or action.recipient != playback.recipient) return error.InvalidActorPlayback;
        };
        for (self.scripted_actors, 0..) |maybe, actor| if (maybe) |binding| {
            if (binding.resource >= bundle.animations.resources.len or self.owns(actor)) return error.InvalidActorPlayback;
            switch (binding.family) {
                .physical => {
                    if (bundle.physical == null or binding.leader >= self.physical_actions.len) return error.InvalidActorPlayback;
                    const action = self.physical_actions[binding.leader] orelse return error.InvalidActorPlayback;
                    if ((actor != action.owner and actor != action.recipient) or (actor == action.owner and action.owner_done) or (actor == action.recipient and action.recipient_done)) return error.InvalidActorPlayback;
                },
                .counter => {
                    if (bundle.counter == null or binding.leader >= self.counter_actions.len) return error.InvalidActorPlayback;
                    const action = self.counter_actions[binding.leader] orelse return error.InvalidActorPlayback;
                    if ((action.kind == .cover) != (action.guard != null)) return error.InvalidActorPlayback;
                    if (action.guard) |guard| if (guard >= self.actors.len or guard == action.attacker or guard == action.defender) return error.InvalidActorPlayback;
                    if (action.action) |controller| if (controller.kind != action.kind or controller.attacker != action.attacker or controller.defender != action.defender or controller.guard != action.guard or controller.critical != action.critical) return error.InvalidActorPlayback;
                    const is_guard = action.guard != null and action.guard.? == actor;
                    const is_assistant = action.cooperation.assistant != null and action.cooperation.assistant.? == actor;
                    if (action.cooperation.assistant) |assistant| if (assistant >= self.actors.len or assistant == action.attacker or assistant == action.defender or action.guard == assistant or bundle.counter.?.cooperation == null) return error.InvalidActorPlayback;
                    if ((actor != action.attacker and actor != action.defender and !is_guard and !is_assistant) or (actor == action.attacker and action.attacker_done) or (actor == action.defender and action.defender_done) or (is_guard and action.guard_done) or (is_assistant and action.cooperation.assistant_done)) return error.InvalidActorPlayback;
                },
                .enemy_magic => {
                    if ((bundle.enemy_magic == null and bundle.enemy_area_magic == null) or binding.leader >= self.enemy_magic_actions.len) return error.InvalidActorPlayback;
                    const action = self.enemy_magic_actions[binding.leader] orelse return error.InvalidActorPlayback;
                    if (!action.prepared or (actor == action.owner and action.owner_done) or (actor != action.owner and !action.ownsRecipient(actor))) return error.InvalidActorPlayback;
                },
                .commander => {
                    if (binding.leader >= self.commander_actions.len) return error.InvalidActorPlayback;
                    const action = self.commander_actions[binding.leader] orelse return error.InvalidActorPlayback;
                    if (actor == action.owner and !std.mem.eql(u8, bundle.animations.resources[binding.resource].id, action.id)) return error.InvalidActorPlayback;
                    const is_recipient = action.recipient != null and action.recipient.? == actor;
                    if (action.action == null or (actor != action.owner and !is_recipient) or (actor == action.owner and action.owner_done) or (is_recipient and action.recipient_done)) return error.InvalidActorPlayback;
                },
                .enemy_wave => {
                    if (binding.leader >= self.wave_actions.len or actor != binding.leader) return error.InvalidActorPlayback;
                    const action = self.wave_actions[binding.leader] orelse return error.InvalidActorPlayback;
                    if (action.action == null or bundle.enemy_wave == null or !std.mem.eql(u8, bundle.animations.resources[binding.resource].id, bundle.enemy_wave.?.id)) return error.InvalidActorPlayback;
                },
            }
            const resource = bundle.animations.resources[binding.resource];
            const clip = resource.find(self.actors[actor].animation) orelse return error.InvalidActorPlayback;
            if (self.actors[actor].frame >= clip.frames.len or (self.actors[actor].animating and self.actors[actor].frame_remaining == 0)) return error.InvalidActorPlayback;
            if (self.actors[actor].machine) |*machine| {
                const index = binding.program orelse return error.InvalidActorPlayback;
                if (index >= bundle.programs.programs.len or machine.actor != actor or (machine.pc >= bundle.programs.programs[index].instructions.len and !machine.halted)) return error.InvalidActorPlayback;
            } else if (binding.program != null) return error.InvalidActorPlayback;
        };
        for (self.members, 0..) |maybe, actor| if (maybe) |member| {
            if (member.pending_dispatch and (!member.initialized or (member.returning and member.program != member.return_program) or self.actors[actor].machine != null)) return error.InvalidActorPlayback;
            if (member.deferred_entry and (member.initialized or member.pending_dispatch or self.actors[actor].machine != null)) return error.InvalidActorPlayback;
            if (member.reaction_variant > 3) return error.InvalidActorPlayback;
            if (member.resource >= bundle.animations.resources.len or member.program >= bundle.programs.programs.len or (member.return_program != null and member.return_program.? >= bundle.programs.programs.len) or member.leader >= self.members.len or member.target >= self.actors.len or bundle.find(member.record) == null) return error.InvalidActorPlayback;
            const bound = for (bundle.find(member.record).?.members) |binding| {
                if (std.mem.eql(u8, binding.id, bundle.animations.resources[member.resource].id)) break binding;
            } else return error.InvalidActorPlayback;
            if ((member.fan == null) != (bound.fan == null) or member.reaction_group != bound.reaction_group) return error.InvalidActorPlayback;
            const clip = bundle.animations.resources[member.resource].find(self.actors[actor].animation) orelse return error.InvalidActorPlayback;
            if (self.actors[actor].frame >= clip.frames.len or self.actors[actor].animating and self.actors[actor].frame_remaining == 0) return error.InvalidActorPlayback;
            if (self.actors[actor].machine) |machine| if (machine.actor != actor or (machine.pc >= bundle.programs.programs[member.program].instructions.len and !machine.halted)) return error.InvalidActorPlayback;
        };
        if (self.auxiliary_capacity > self.auxiliary.len) return error.InvalidActorPlayback;
        for (self.auxiliary, self.auxiliary_bindings, 0..) |maybe, binding, index| {
            if ((maybe == null) != (binding == null)) return error.InvalidActorPlayback;
            const child = maybe orelse continue;
            const ids = binding.?;
            if (index >= self.auxiliary_capacity or ids.resource >= bundle.animations.resources.len or ids.program >= bundle.programs.programs.len or child.machine == null) return error.InvalidActorPlayback;
            const clip = bundle.animations.resources[ids.resource].find(child.animation) orelse return error.InvalidActorPlayback;
            if (child.frame >= clip.frames.len or (child.animating and child.frame_remaining == 0)) return error.InvalidActorPlayback;
            const machine = child.machine.?;
            if (machine.actor != self.actors.len + index or (machine.pc >= bundle.programs.programs[ids.program].instructions.len and !machine.halted)) return error.InvalidActorPlayback;
            if (child.owner) |owner| {
                if (owner < self.actors.len and owner >= actor_capacity - @as(usize, self.auxiliary_capacity)) return error.InvalidActorPlayback;
                if (owner >= self.actors.len and (owner - self.actors.len >= self.auxiliary_capacity or self.auxiliary[owner - self.actors.len] == null)) return error.InvalidActorPlayback;
            } else return error.InvalidActorPlayback;
        }
        for (self.scripted_actors, 0..) |maybe, actor| if (maybe) |binding| {
            self.actors[actor].resource = bundle.animations.resources[binding.resource];
            if (self.actors[actor].machine) |*machine| machine.instructions = bundle.programs.programs[binding.program.?].instructions;
        };
        for (self.members, 0..) |maybe, actor| if (maybe) |member| {
            self.actors[actor].resource = bundle.animations.resources[member.resource];
            if (self.actors[actor].machine) |*machine| machine.instructions = bundle.programs.programs[member.program].instructions;
        };
        for (&self.auxiliary, self.auxiliary_bindings) |*maybe, binding| if (binding) |ids| {
            maybe.*.?.resource = bundle.animations.resources[ids.resource];
            maybe.*.?.machine.?.instructions = bundle.programs.programs[ids.program].instructions;
        };
    }
    fn bindAuxiliary(self: *State, bundle: *const host.Bundle) !void {
        for (&self.scripted_actors, 0..) |*maybe, actor| if (maybe.*) |*binding| {
            binding.program = null;
            if (self.actors[actor].machine) |machine| {
                binding.program = for (bundle.programs.programs, 0..) |program, index| {
                    if (program.instructions.ptr == machine.instructions.ptr) break @intCast(index);
                } else return error.MissingPhysicalProgram;
            }
        };
        for (self.auxiliary, 0..) |maybe, index| {
            const child = maybe orelse {
                self.auxiliary_bindings[index] = null;
                continue;
            };
            const resource = child.resource orelse return error.InvalidActorPlayback;
            const machine = child.machine orelse return error.InvalidActorPlayback;
            var binding: AuxiliaryBinding = undefined;
            binding.resource = for (bundle.animations.resources, 0..) |candidate, id| {
                if (std.mem.eql(u8, candidate.id, resource.id)) break @intCast(id);
            } else return error.MissingActorResource;
            binding.program = for (bundle.programs.programs, 0..) |candidate, id| {
                if (candidate.instructions.ptr == machine.instructions.ptr) break @intCast(id);
            } else return error.MissingUniteProgram;
            self.auxiliary_bindings[index] = binding;
        }
    }
    fn memberSlot(self: State, bundle: *const host.Bundle, leader: u8, id: []const u8) ?usize {
        for (self.members, 0..) |maybe, slot| if (maybe) |member| {
            if (member.leader == leader and std.mem.eql(u8, bundle.animations.resources[member.resource].id, id)) return slot;
        };
        return null;
    }
    // Controller objects are separate from the script actor pool and retain their initial pose.
    pub fn advanceFans(self: *State, bundle: *const host.Bundle, flags: [12]u16) !void {
        for (&self.members, 0..) |*maybe, actor| if (maybe.*) |*member| {
            const fan = if (member.fan) |*value| value else continue;
            const binding = bundle.find(member.record) orelse return error.InvalidActorPlayback;
            const spec = for (binding.members) |candidate| {
                if (std.mem.eql(u8, candidate.id, bundle.animations.resources[member.resource].id)) break candidate.fan orelse return error.InvalidActorPlayback;
            } else return error.InvalidActorPlayback;
            if (!member.initialized or fan.finished) {
                fan.visible = false;
                continue;
            }
            fan.anchor = .{ self.actors[actor].position_q12[0] >> 12, self.actors[actor].position_q12[1] >> 12, spec.anchor_z };
            fan.visible = fan.visible or flags[actor] & spec.signal != 0;
            if (fan.visible) fan.local_x_q12 = std.math.add(i32, fan.local_x_q12, spec.velocity_q12) catch return error.InvalidActorPlayback;
            // This callback queues its final draw before freeing all ten objects.
            fan.finished = self.allReady(member.leader);
        };
    }
    pub fn advanceTransition(self: *State, bundle: *const host.Bundle, leader: u8, flags: *[12]u16) !void {
        const record = for (self.members) |maybe| {
            if (maybe) |member| if (member.leader == leader) break member.record;
        } else return;
        const binding = bundle.find(record) orelse return error.InvalidUniteBindings;
        const transition = binding.transition orelse return;
        const trigger = self.memberSlot(bundle, leader, binding.members[transition.trigger_member].id) orelse return;
        if (!self.members[trigger].?.initialized) return;
        if (flags[trigger] & transition.signal == 0) return;
        var next = self.*;
        for (transition.dispatches) |dispatch| {
            const slot = self.memberSlot(bundle, leader, binding.members[dispatch.member].id) orelse return error.MissingUniteParticipant;
            const member = &next.members[slot].?;
            if (member.returning or member.pending_dispatch or (!member.initialized and !member.deferred_entry)) return error.InvalidActorPlayback;
            member.program = try programIndex(bundle, dispatch.program);
            member.pending_dispatch = member.initialized;
            member.deferred_entry = false;
            next.actors[slot].machine = null;
        }
        next.actors[trigger].signals &= ~transition.signal;
        flags[trigger] &= ~transition.signal;
        self.* = next;
    }
    pub fn advanceCallbackChild(self: *State, state: *CombatState, leader: u8, target_position: [3]i32, attachment: [2]i16, initial_camera: camera.Block) !void {
        const bundle = state.unite_actors orelse return error.MissingActorLibrary;
        const parent = for (self.members, 0..) |maybe, actor| {
            if (maybe) |member| if (member.leader == leader and member.initialized) {
                const binding = bundle.find(member.record).?;
                if (binding.beat_child != null and std.mem.eql(u8, binding.members[1].id, bundle.animations.resources[member.resource].id)) break actor;
            };
        } else return;
        if (self.actors[parent].shared_value != 1) return;
        const member = self.members[parent].?;
        if (!self.ownsActor(member.target)) self.actors[member.target] = host.Actor.anchor(target_position, target_position, attachment);
        var context = RuntimeContext{ .state = state, .playback = self, .initial_camera = initial_camera };
        var runtime = host.Runtime{ .actors = &self.actors, .auxiliary = self.auxiliary[0..self.auxiliary_capacity], .library = bundle.library(), .external = .{ .context = &context, .command = RuntimeContext.command } };
        context.runtime = &runtime;
        const child = bundle.find(member.record).?.beat_child.?;
        _ = try @import("battle_unite_beat.zig").spawnChild(&runtime, @intCast(parent), member.target, child);
        try self.bindAuxiliary(bundle);
    }
    pub fn sequenceDispatch(self: *State, bundle: *const host.Bundle, actor: usize, target: ?u8) !void {
        if (!self.owns(actor)) return error.InvalidActorBinding;
        const member = &self.members[actor].?;
        if (!member.initialized or member.returning or member.pending_dispatch) return error.InvalidActorPlayback;
        const binding = bundle.find(member.record) orelse return error.InvalidUniteBindings;
        const resource = bundle.animations.resources[member.resource];
        const selected = for (binding.members) |candidate| {
            if (std.mem.eql(u8, candidate.id, resource.id)) break candidate;
        } else return error.MissingUniteParticipant;
        if (target) |recipient| {
            if (recipient >= self.actors.len) return error.InvalidActorBinding;
            member.program = try programIndex(bundle, selected.loop_program orelse return error.MissingUniteProgram);
            member.target = recipient;
        } else {
            member.program = member.return_program orelse return error.MissingUniteProgram;
            member.returning = true;
        }
        member.pending_dispatch = true;
        self.actors[actor].machine = null;
        self.actors[actor].signals &= ~@as(u16, 16);
    }
    pub fn advancePhysical(self: *State, state: *CombatState, initial_camera: camera.Block) !void {
        const bundle = state.unite_actors orelse return;
        if (!self.hasPhysical() and !self.hasCounter() and !self.hasEnemyMagic() and !self.hasCommander() and !self.hasEnemyWave()) return;
        try self.rebind(bundle);
        self.beginSoundFrame(state.camera_ticks);
        var context = RuntimeContext{ .state = state, .playback = self, .initial_camera = initial_camera };
        var runtime = host.Runtime{ .actors = &self.actors, .auxiliary = self.auxiliary[0..self.auxiliary_capacity], .library = bundle.library(), .camera_controller = if (state.actor_camera) |*value| value else null, .external = .{ .context = &context, .command = RuntimeContext.command, .after_actor = RuntimeContext.after, .previous_screen_position = RuntimeContext.previous, .hold_coordinator_dispatch = RuntimeContext.holdCoordinatorDispatch, .tail_return = RuntimeContext.tailReturn, .decoy_contact = RuntimeContext.decoy } };
        context.runtime = &runtime;
        if (self.physical_logic_at == state.camera_ticks) {
            for (&self.counter_actions, 0..) |*maybe, leader| if (maybe.*) |*playback| {
                if (playback.action != null or state.camera_ticks < playback.start_at or playback.attacker < state.partyCount()) continue;
                if (playback.kind == .projectile or std.mem.eql(u8, state.enemy(playback.attacker - state.partyCount()).id, "killer_rabbit") or state.enemy(playback.attacker - state.partyCount()).action_policy == .source_projectile) try state.prepareCounter(leader, &runtime);
            };
            try self.bindAuxiliary(bundle);
            return;
        }
        for (&self.physical_actions, 0..) |*maybe, leader| if (maybe.*) |*playback| {
            const packet = bundle.physicalPacket() orelse return error.MissingActorLibrary;
            if (state.camera_ticks < playback.start_at) continue;
            if (playback.action == null) try state.preparePhysicalRune(leader, &runtime);
            const before = playback.action.?.stage;
            try playback.action.?.advance(packet, &runtime);
            if (before == .auxiliary and playback.action.?.stage == .recipient) state.physical_numerator = packet.find(playback.technique).?.numerator;
            if (playback.action.?.stage == .released) state.finishPhysicalRuneController(leader);
        };
        for (self.commander_actions, 0..) |maybe, owner| if (maybe != null) try state.advanceCommander(owner, &runtime);
        for (self.wave_actions, 0..) |maybe, owner| if (maybe != null) try state.advanceEnemyWave(owner, &runtime);
        for (&self.counter_actions, 0..) |*maybe, leader| if (maybe.*) |*playback| {
            if (state.camera_ticks < playback.start_at) continue;
            if (playback.action == null) try state.prepareCounter(leader, &runtime);
        };
        for (&self.enemy_magic_actions, 0..) |*maybe, owner| if (maybe.*) |*playback| {
            if (state.camera_ticks >= playback.start_at and !playback.prepared) try state.prepareEnemyMagic(owner, &runtime);
        };
        // All callback families share the original ascending actor sweep after the primary controller.
        for (0..state.partyCount() + state.enemyCount()) |actor| {
            const packet = bundle.physicalPacket();
            for (&self.physical_actions, 0..) |*maybe, leader| if (maybe.*) |*playback| {
                if (playback.recipient != actor or playback.action == null or !playback.action.?.damageReady(packet.?, runtime)) continue;
                try state.applyPhysicalRuneContact(leader);
                try playback.action.?.acknowledgeDamage(packet.?, &runtime);
            };
            if (bundle.counterPacket()) |counter_packet| for (&self.counter_actions, 0..) |*maybe, leader| if (maybe.*) |*playback| {
                if (playback.action == null or playback.controller_done) continue;
                const callback_actor = playback.action.?.callbackActor() orelse continue;
                if (callback_actor != actor) continue;
                const approaching = playback.action.?.stage == .approach;
                try playback.action.?.advance(counter_packet, &runtime);
                if (approaching and playback.kind.miss() and playback.action.?.stage == .hurt) {
                    playback.miss_at = state.camera_ticks;
                }
                if (playback.action.?.stage == .contact) {
                    try state.applyCounterContact(leader);
                    try playback.action.?.acknowledgeContact(counter_packet, &runtime);
                }
                if (playback.action.?.returnReady(runtime)) {
                    if (try state.repeatCounter(leader, &runtime)) continue;
                    try playback.action.?.beginReturn(counter_packet, &runtime);
                    state.finishCounterController(leader);
                }
            };
        }
        try self.bindAuxiliary(bundle);
        for (0..state.partyCount() + state.enemyCount()) |actor| state.unite_flags[actor] = self.actors[actor].signals;
        self.physical_logic_at = state.camera_ticks;
    }
    pub fn update(self: *State, state: *CombatState, initial_camera: camera.Block) !void {
        const bundle = state.unite_actors orelse return error.MissingActorLibrary;
        try self.rebind(bundle);
        try self.advanceFans(bundle, state.unite_flags);
        self.beginSoundFrame(state.camera_ticks);
        var initializing = false;
        for (&self.prepare_at, 0..) |*pending, leader| if (pending.*) |at| {
            if (state.camera_ticks < at) continue;
            const controller_owned = for (self.members) |maybe| {
                if (maybe) |member| if (member.leader == leader) break bundle.find(member.record).?.controller != null or bundle.find(member.record).?.target_queue != null or bundle.find(member.record).?.wave_heights != null;
            } else false;
            if (controller_owned) try state.prepareUniteScene(leader);
            const impact_owned = for (self.members) |maybe| {
                if (maybe) |member| if (member.leader == leader) break bundle.find(member.record).?.impact_effect != null;
            } else false;
            if (impact_owned) try state.prepareUniteImpactEffect(leader);
            initializing = true;
            for (self.members, 0..) |maybe, actor| if (maybe) |member| {
                if (member.leader != leader) continue;
                self.actors[actor].signals = 0;
                state.unite_flags[actor] = 0;
            };
            pending.* = null;
        };
        if (initializing) for (state.partyCount()..state.partyCount() + state.enemyCount()) |actor| {
            self.actors[actor].signals = 0;
            state.unite_flags[actor] = 0;
        };
        var context = RuntimeContext{ .state = state, .playback = self, .initial_camera = initial_camera };
        var runtime = host.Runtime{ .actors = &self.actors, .auxiliary = self.auxiliary[0..self.auxiliary_capacity], .library = bundle.library(), .camera_angles = .{ @truncate(initial_camera.angles[0]), @truncate(initial_camera.angles[1]), @truncate(initial_camera.angles[2]) }, .camera_controller = if (state.actor_camera) |*value| value else null, .external = .{ .context = &context, .command = RuntimeContext.command, .after_actor = RuntimeContext.after, .previous_screen_position = RuntimeContext.previous, .hold_coordinator_dispatch = RuntimeContext.holdCoordinatorDispatch, .tail_return = RuntimeContext.tailReturn, .decoy_contact = RuntimeContext.decoy } };
        context.runtime = &runtime;
        for (&self.members, 0..) |*maybe, actor| if (maybe.*) |*member| {
            if (member.deferred_entry or state.camera_ticks < member.start_at) continue;
            if (!member.initialized or member.pending_dispatch) {
                try runtime.dispatch(@intCast(actor), member.target, bundle.programs.programs[member.program]);
                member.initialized = true;
                member.pending_dispatch = false;
            } else {
                self.actors[actor].signals = state.unite_flags[actor];
                if (!member.returning and self.actors[actor].signals & 4 != 0) {
                    if (state.unite_scene) |scene| {
                        const controller = bundle.find(scene.record).?.controller.?;
                        if (scene.owner == member.leader and controller.mode == .owner_clock and (state.active.?.scene == null or state.active.?.scene.?.elapsed < controller.return_at.?)) continue;
                    }
                    self.actors[actor].signals &= ~@as(u16, 4);
                    state.unite_flags[actor] &= ~@as(u16, 4);
                    if (member.return_program) |program| {
                        member.program = program;
                        try runtime.dispatch(@intCast(actor), member.target, bundle.programs.programs[member.program]);
                    }
                    member.returning = true;
                }
            }
        };
        for (0..state.partyCount() + state.enemyCount()) |actor| {
            const member = if (actor < self.members.len) self.members[actor] else null;
            const idle = state.hasSourceEnemyIdle(actor);
            if (!idle and self.scripted_actors[actor] == null and (member == null or !member.?.initialized)) continue;
            try state.stepEnemyIdleActor(&runtime, @intCast(actor));
            if (member != null) self.members[actor].?.age += 1;
        }
        // Newborn children in later slots participate in this same ascending sweep.
        for (0..self.auxiliary_capacity) |index| if (self.auxiliary[index] != null) try runtime.stepActor(@intCast(self.actors.len + index));
        try self.bindAuxiliary(bundle);
        for (0..state.partyCount() + state.enemyCount()) |actor| state.unite_flags[actor] = self.actors[actor].signals;
    }
};
