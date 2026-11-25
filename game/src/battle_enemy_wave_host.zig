const std = @import("std");
const battle = @import("battle.zig");
const host = @import("battle_actor_host.zig");
const layout = @import("battle_layout.zig");
const reactions = @import("battle_counter_host.zig");
const art = @import("battle_physical_host.zig");
const State = battle.State;

pub fn hasSourceEnemyWave(self: State, owner: usize) bool {
    if (owner < self.partyCount() or owner >= self.partyCount() + self.enemyCount() or self.enemy(owner - self.partyCount()).action_policy != .source_holly_fairy) return false;
    const binding = (self.unite_actors orelse return false).enemy_wave orelse return false;
    return std.mem.eql(u8, binding.id, self.enemy(owner - self.partyCount()).id);
}

pub fn beginSourceEnemyWave(self: *State, owner: usize) !void {
    if (!self.hasSourceEnemyWave(owner) or !self.participates(owner)) return error.MissingEnemyWaveBinding;
    if (self.active != null or !reactions.reactionAvailable(self, owner) or self.unite_vm.wave_actions[owner] != null) return error.ActorAlreadyOwned;
    const bundle = self.unite_actors.?;
    const binding = bundle.enemy_wave.?;
    if (self.content.presentation_ready) try art.checkProgramArt(self.*, bundle, bundle.animations.find(binding.id).?, binding.owner_program, 0, 0, false);
    self.unite_vm.auxiliary_capacity = @intCast(19 - self.partyCount() - self.enemyCount());
    self.unite_vm.wave_actions[owner] = .{ .owner = @intCast(owner), .start_at = self.camera_ticks +% 1 };
    self.active = .{ .actor = owner, .target = owner, .kind = .enemy_command };
    self.acted[owner] = true;
    if (self.coordinator) |*clock| clock.stage = .await_order;
}

const Delegate = struct {
    state: *State,
    runtime: *host.Runtime,
    target: ?usize = null,

    pub fn partyCount(self: Delegate) usize {
        return self.state.partyCount();
    }
    pub fn enemyCount(self: Delegate) usize {
        return self.state.enemyCount();
    }
    pub fn eligible(self: Delegate, actor: usize) bool {
        return !self.state.acted[actor] and self.state.participates(actor) and !self.state.coordinatorLocked(actor);
    }
    pub fn decision(self: *Delegate, actor: usize) !battle.enemy_wave.Decision {
        const policy = self.state.enemy(actor - self.partyCount()).action_policy;
        // shortcut: delegated specials need their own decision/ownership qualification before admission.
        if (policy != .source_melee and policy != .source_projectile and
            !(policy == .source_holly_fairy and self.state.enemyRow(actor - self.partyCount()) == .front)) return error.UnsupportedEnemyWaveDecision;
        var eligible_target = false;
        self.target = try self.state.scanSourceEnemyTarget(actor, &eligible_target);
        if (self.target != null) return .ordinary_attack;
        if (!eligible_target or policy == .source_holly_fairy) self.state.acted[actor] = true;
        return .no_action;
    }
    pub fn ordinary(self: *Delegate, actor: usize) !bool {
        const target = self.target orelse return error.InvalidActorBinding;
        if (self.state.coordinatorLocked(target)) return false;
        const started = self.state.sourceEnemyAttack(actor, target);
        if (self.state.replay_exhausted) return error.RandomInputExhausted;
        if (self.state.replay_unsupported != null) return error.UnsupportedEnemyWaveAttack;
        if (started) for (&self.state.unite_vm.counter_actions) |*maybe| if (maybe.*) |*playback| {
            // This resolver runs in the primary phase, before this update's actor preparation.
            if (playback.attacker == actor and playback.action == null) playback.start_at = self.state.camera_ticks;
        };
        return started;
    }
    pub fn markStarted(self: Delegate, actor: usize) void {
        self.state.acted[actor] = true;
        self.runtime.actors[actor].signals = 0;
        self.state.unite_flags[actor] = 0;
    }
    pub fn restoreWave(_: Delegate, _: usize) void {}
    pub fn restoreOwner(self: Delegate, owner: usize) void {
        if (self.state.coordinator) |*clock| clock.current_actor = owner;
    }
};

pub fn advanceEnemyWave(self: *State, owner: usize, runtime: *host.Runtime) !void {
    if (!self.hasSourceEnemyWave(owner)) return error.InvalidActorBinding;
    const playback = &self.unite_vm.wave_actions[owner].?;
    if (self.camera_ticks < playback.start_at) return;
    if (playback.action == null) {
        const bundle = self.unite_actors.?;
        const resource = for (bundle.animations.resources, 0..) |value, index| {
            if (std.mem.eql(u8, value.id, "holly_fairy")) break index;
        } else return error.MissingActorResource;
        const point = layout.worldPosition(self, owner);
        const position: [3]i32 = .{ @intFromFloat(@round(point.x * 4096)), @intFromFloat(@round(point.y * 4096)), @intFromFloat(@round(point.z * 4096)) };
        try reactions.yieldReactionActor(self, owner);
        runtime.actors[owner] = try @import("battle_enemy_idle.zig").prepareActor(self, owner, bundle.animations.resources[resource], position);
        self.unite_vm.scripted_actors[owner] = .{ .family = .enemy_wave, .leader = @intCast(owner), .resource = @intCast(resource) };
        self.unite_flags[owner] = 0;
        playback.action = try battle.enemy_wave.Action.begin(runtime, @intCast(owner));
    }
    var context = Delegate{ .state = self, .runtime = runtime };
    if (try playback.action.?.advance(runtime, &context) == .completed) {
        playback.completed_at = self.camera_ticks;
        if (self.coordinator) |*clock| {
            clock.stage = .select;
            clock.completed = true;
            clock.remaining = battle.enemy_wave.selection_delay;
        }
        if (self.active) |effect| if (effect.actor == owner and effect.kind == .enemy_command) {
            self.active = null;
        };
    }
}

pub fn finishEnemyWaveActors(self: *State) void {
    for (&self.unite_vm.wave_actions, 0..) |*maybe, owner| if (maybe.*) |playback| {
        if (playback.action == null or !playback.action.?.completed) continue;
        const actor = self.unite_vm.actors[owner];
        if (actor.machine == null or !actor.machine.?.halted or actor.highlights != 0) continue;
        reactions.retainPosition(self, owner);
        self.unite_vm.scripted_actors[owner] = null;
        maybe.* = null;
    };
}
