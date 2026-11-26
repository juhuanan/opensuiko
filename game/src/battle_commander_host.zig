const std = @import("std");
const battle = @import("battle.zig");
const host = @import("battle_actor_host.zig");
const layout = @import("battle_layout.zig");
const art = @import("battle_physical_host.zig");
const reactions = @import("battle_counter_host.zig");
const State = battle.State;

fn q12(point: battle.Position) [3]i32 {
    return .{ @intFromFloat(@round(point.x * 4096)), @intFromFloat(@round(point.y * 4096)), @intFromFloat(@round(point.z * 4096)) };
}
pub fn hasSourceCommander(self: State, owner: usize) bool {
    if (owner < self.partyCount() or owner >= self.partyCount() + self.enemyCount()) return false;
    const policy = self.enemy(owner - self.partyCount()).action_policy;
    if (policy != .commander and policy != .source_commander and policy != .source_whip_wolf) return false;
    const binding = (self.unite_actors orelse return false).commanderFor(self.enemy(owner - self.partyCount()).id) orelse return false;
    return std.mem.eql(u8, self.enemy(owner - self.partyCount()).id, binding.id);
}
pub fn beginSourceCommander(self: *State, owner: usize, recipient: ?usize) !void {
    if (!self.hasSourceCommander(owner) or !self.participates(owner)) return error.MissingEnemyOrderBinding;
    if (!reactions.reactionAvailable(self, owner) or self.unite_vm.commander_actions[owner] != null or self.active != null) return error.ActorAlreadyOwned;
    if (recipient) |target| if (target >= self.partyCount() or !self.participates(target) or self.coordinatorLocked(target) or !reactions.reactionAvailable(self, target)) return error.ActorAlreadyOwned;
    const bundle = self.unite_actors.?;
    const binding = bundle.commanderFor(self.enemy(owner - self.partyCount()).id).?;
    if (recipient != null and binding.solo_program == null) return error.InvalidActorBinding;
    if (self.content.presentation_ready) {
        try art.checkProgramArt(self.*, bundle.library(), bundle.animations.find(binding.id).?, if (recipient == null) binding.order_program else binding.solo_program.?, 0, 0, false);
        if (recipient) |target| try art.checkProgramArt(self.*, bundle.library(), bundle.animations.find(self.progress.party.at(target).id) orelse return error.MissingActorResource, binding.recipient_program.?, 0, 0, false);
    }
    self.unite_vm.auxiliary_capacity = @intCast(19 - self.partyCount() - self.enemyCount());
    self.unite_vm.commander_actions[owner] = .{ .id = binding.id, .owner = @intCast(owner), .recipient = if (recipient) |target| @intCast(target) else null, .start_at = self.camera_ticks +% 1, .recipient_done = recipient == null };
    self.active = .{ .actor = owner, .target = recipient orelse owner, .kind = .enemy_command };
    self.acted[owner] = true;
    if (self.coordinator) |*clock| {
        clock.stage = if (recipient == null) .await_order else .select;
        if (recipient != null) clock.remaining = 0;
    }
}
fn prepareActor(self: *State, actor: usize, owner: usize, runtime: *host.Runtime) !void {
    const bundle = self.unite_actors.?;
    const id = if (actor < self.partyCount()) self.progress.party.at(actor).id else self.enemy(actor - self.partyCount()).id;
    const resource = for (bundle.animations.resources, 0..) |value, index| {
        if (std.mem.eql(u8, value.id, id)) break index;
    } else return error.MissingActorResource;
    const position = q12(layout.worldPosition(self, actor));
    try reactions.yieldReactionActor(self, actor);
    runtime.actors[actor] = try host.Actor.init(bundle.animations.resources[resource], q12(self.uniteVmHome(actor)));
    runtime.actors[actor].position_q12 = position;
    runtime.actors[actor].screen_offset = self.actor_transforms[actor].screen_offset;
    runtime.actors[actor].baseline_offset = (if (actor < self.partyCount()) self.partyProfile(actor) else self.enemy(actor - self.partyCount())).effect_offset orelse .{ 0, 0 };
    self.unite_vm.scripted_actors[actor] = .{ .family = .commander, .leader = @intCast(owner), .resource = @intCast(resource) };
    self.unite_flags[actor] = 0;
}
pub fn advanceCommander(self: *State, owner: usize, runtime: *host.Runtime) !void {
    const playback = &self.unite_vm.commander_actions[owner].?;
    const binding = self.unite_actors.?.commanderFor(playback.id) orelse return error.MissingEnemyOrderBinding;
    if (self.camera_ticks < playback.start_at) return;
    if (playback.action == null) {
        try prepareActor(self, owner, owner, runtime);
        if (playback.recipient) |target| try prepareActor(self, target, owner, runtime);
        playback.action = try battle.commander.Action.begin(binding, runtime, @intCast(owner), playback.recipient);
    }
    if (try playback.action.?.advance(binding, runtime) != .orders) return;
    playback.ordered_at = self.camera_ticks;
    for (self.partyCount()..self.partyCount() + self.enemyCount()) |ally| {
        if (ally == owner or !self.participates(ally) or self.acted[ally] or self.coordinatorLocked(ally)) continue;
        const target = self.formationMember(ally - self.partyCount());
        if (target >= self.partyCount() or !self.participates(target) or self.coordinatorLocked(target)) continue;
        try reactions.beginOrderedAttack(self, ally, target);
        self.acted[ally] = true;
    }
    if (self.coordinator) |*clock| {
        clock.stage = .select;
        clock.remaining = @intCast(binding.selection_delay);
    }
}
pub fn finishCommanderActors(self: *State) void {
    for (&self.unite_vm.commander_actions, 0..) |*maybe, owner| if (maybe.*) |*playback| {
        if (playback.action == null) continue;
        if (!playback.controller_done and self.unite_vm.actors[owner].released) {
            playback.controller_done = true;
            if (self.active) |effect| if (effect.kind == .enemy_command and effect.actor == owner) {
                self.active = null;
            };
            if (self.coordinator) |*clock| if (clock.current_actor == owner) {
                clock.completed = true;
            };
        }
        for ([2]?u8{ playback.owner, playback.recipient }, 0..) |maybe_actor, role| {
            const actor = maybe_actor orelse continue;
            const binding = self.unite_vm.scripted_actors[actor] orelse continue;
            if (binding.family != .commander or binding.leader != owner) continue;
            const current = self.unite_vm.actors[actor];
            if (current.machine == null or !current.machine.?.halted or current.highlights != 0) continue;
            if (role == 0 and !playback.controller_done) continue;
            reactions.retainPosition(self, actor);
            self.unite_vm.scripted_actors[actor] = null;
            if (role == 0) playback.owner_done = true else playback.recipient_done = true;
        }
        if (playback.owner_done and playback.recipient_done) maybe.* = null;
    };
}
