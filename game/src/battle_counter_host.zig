const std = @import("std");
const battle = @import("battle.zig");
const host = @import("battle_actor_host.zig");
const art = @import("battle_physical_host.zig");
const layout = @import("battle_layout.zig");
const passive = @import("battle_systems").techniques.passive;
const State = battle.State;

fn q12(position: battle.Position) [3]i32 {
    return .{ @intFromFloat(@round(position.x * 4096)), @intFromFloat(@round(position.y * 4096)), @intFromFloat(@round(position.z * 4096)) };
}
pub fn counterAvailable(self: *State, attacker: usize, defender: usize) !bool {
    if (attacker <= self.partyCount() or defender >= self.partyCount()) return false;
    const packet = (self.unite_actors orelse return false).counterPacket() orelse return false;
    const enemy = packet.enemy(self.enemy(attacker - self.partyCount()).id) orelse return error.MissingCounterCapability;
    if (!enemy.counterable) return false;
    const range = self.partyProfile(defender).weapon_range orelse return error.MissingCounterWeaponRange;
    var input = passive.Input{ .actor_index = @intCast(attacker + 1), .counter_actor_floor = @intCast(self.partyCount() + 1), .attacker_capability = enemy.counterable, .target_persistent_flag = range != .long, .target_slot_47 = self.actions[defender] != null and self.actions[defender].? == .defend, .target_rune = self.runeByteFor(defender) orelse 0, .roll_low_bit = 0 };
    const decision = passive.decide(input);
    if (decision == .granted) return true;
    if (decision.refused != .random_low_bit) return false;
    input.roll_low_bit = @truncate(self.roll());
    if (self.replay_exhausted) return error.RandomInputExhausted;
    return passive.decide(input) == .granted;
}
pub fn beginCounter(self: *State, attacker: usize, defender: usize) !void {
    if (attacker <= self.partyCount() or defender >= self.partyCount()) return error.InvalidActorBinding;
    try beginReaction(self, attacker, defender, .counter, null, false);
}
pub fn parryAvailable(self: *const State, attacker: usize, defender: usize) !bool {
    if (attacker >= self.partyCount() or defender < self.partyCount()) return false;
    const packet = (self.unite_actors orelse return false).counterPacket() orelse return false;
    if (packet.parries == null) return false;
    const enemy = packet.enemy(self.enemy(defender - self.partyCount()).id) orelse return error.MissingCounterCapability;
    if (packet.defenderFor(enemy.id, .parry) == null) return false;
    const range = self.partyProfile(attacker).weapon_range orelse return error.MissingParryCapability;
    return range != .long;
}
pub fn beginParry(self: *State, attacker: usize, defender: usize) !void {
    if (attacker >= self.partyCount() or defender < self.partyCount()) return error.InvalidActorBinding;
    try beginReaction(self, attacker, defender, .parry, null, false);
}
pub fn beginMelee(self: *State, attacker: usize, defender: usize, hit: bool) !void {
    if (attacker < self.partyCount() or defender >= self.partyCount()) return error.InvalidActorBinding;
    try beginReaction(self, attacker, defender, if (hit) .ordinary_hit else .ordinary_miss, null, false);
}
pub fn beginEnemySpecial(self: *State, attacker: usize, defender: usize) !void {
    if (attacker < self.partyCount() or defender >= self.partyCount()) return error.InvalidActorBinding;
    try beginReaction(self, attacker, defender, .special, null, false);
}
pub fn hasSourceRabbit(self: *const State, actor: usize) bool {
    if (actor < self.partyCount() or actor >= self.partyCount() + self.enemyCount() or !std.mem.eql(u8, self.enemy(actor - self.partyCount()).id, "killer_rabbit")) return false;
    const packet = (self.unite_actors orelse return false).counterPacket() orelse return false;
    const projectile = (packet.meleeEnemy("killer_rabbit") orelse return false).projectile orelse return false;
    return self.enemy(actor - self.partyCount()).action_policy != .source_rabbit or projectile.camera != null;
}
pub fn beginRabbitProjectile(self: *State, attacker: usize, defender: usize) !bool {
    if (!self.hasSourceRabbit(attacker) or defender >= self.partyCount()) return error.InvalidActorBinding;
    const capacity = 19 - self.partyCount() - self.enemyCount();
    const available = for (self.unite_vm.auxiliary[0..capacity]) |slot| {
        if (slot == null) break true;
    } else false;
    if (!available) return false;
    try beginReaction(self, attacker, defender, .projectile, null, false);
    return true;
}
pub fn beginRanged(self: *State, attacker: usize, defender: usize, hit: bool, critical: bool) !void {
    if (attacker >= self.partyCount() or defender < self.partyCount()) return error.InvalidActorBinding;
    if (critical and !hit) return error.InvalidActorBinding;
    try beginReaction(self, attacker, defender, if (hit) .ranged_hit else .ranged_miss, null, critical);
}
pub fn beginPartyMelee(self: *State, attacker: usize, defender: usize, hit: bool, critical: bool) !void {
    if (attacker >= self.partyCount() or defender < self.partyCount() or (critical and !hit)) return error.InvalidActorBinding;
    try beginReaction(self, attacker, defender, if (hit) .melee_hit else .melee_miss, null, critical);
}
pub fn beginCover(self: *State, attacker: usize, ward: usize, guard: usize) !void {
    if (attacker < self.partyCount() or ward >= self.partyCount() or guard >= self.partyCount() or ward == guard) return error.InvalidActorBinding;
    try beginReaction(self, attacker, ward, .cover, guard, false);
}
pub fn reactionAvailable(self: *const State, actor: usize) bool {
    if (!self.unite_vm.ownsActor(actor)) return true;
    if (self.unite_vm.owns(actor) or self.hp(actor) == 0) return false;
    const binding = self.unite_vm.scripted_actors[actor] orelse return false;
    if (binding.family == .counter) {
        const playback = self.unite_vm.counter_actions[binding.leader] orelse return false;
        return playback.controller_done and self.unite_vm.actors[actor].highlights == 0;
    }
    if (binding.family != .physical) return false;
    const playback = self.unite_vm.physical_actions[binding.leader] orelse return false;
    const action = playback.action orelse return false;
    // Source return scripts may clear their lock before their final animation ends.
    return playback.owner == actor and action.stage == .released and
        self.unite_vm.actors[actor].released and self.unite_vm.actors[actor].highlights == 0;
}
pub fn yieldReactionActor(self: *State, actor: usize) !void {
    if (!reactionAvailable(self, actor)) return error.ActorAlreadyOwned;
    if (self.unite_vm.scripted_actors[actor]) |prior| {
        if (prior.family == .physical) {
            self.unite_vm.physical_actions[prior.leader].?.owner_done = true;
        } else if (prior.family == .counter) {
            const previous = &self.unite_vm.counter_actions[prior.leader].?;
            if (previous.attacker == actor) previous.attacker_done = true else if (previous.defender == actor) previous.defender_done = true else if (previous.guard != null and previous.guard.? == actor) previous.guard_done = true else previous.cooperation.assistant_done = true;
        }
        self.unite_vm.scripted_actors[actor] = null;
    }
}
pub fn beginOrderedAttack(self: *State, attacker: usize, defender: usize) !void {
    if (attacker < self.partyCount() or defender >= self.partyCount()) return error.InvalidActorBinding;
    const active = self.active;
    defer self.active = active;
    try beginReaction(self, attacker, defender, .ordered, null, false);
    for (&self.unite_vm.counter_actions) |*maybe| if (maybe.*) |*playback| {
        if (playback.attacker == attacker and playback.action == null and !playback.controller_done) {
            playback.start_at = self.camera_ticks;
            return;
        }
    };
    return error.MissingCounterProgram;
}
fn beginReaction(self: *State, attacker: usize, defender: usize, kind: battle.counter.Kind, guard: ?usize, critical: bool) !void {
    const bundle = self.unite_actors orelse return error.MissingActorLibrary;
    const packet = bundle.counterPacket() orelse return error.MissingActorLibrary;
    const count = self.partyCount() + self.enemyCount();
    if (attacker >= count or defender >= count or !reactionAvailable(self, attacker) or !reactionAvailable(self, defender)) return error.ActorAlreadyOwned;
    if (guard) |index| if (!reactionAvailable(self, index)) return error.ActorAlreadyOwned;
    const preferred = if (attacker >= self.partyCount()) attacker - self.partyCount() else attacker;
    const leader = if (self.unite_vm.counter_actions[preferred] == null) preferred else for (self.unite_vm.counter_actions, 0..) |value, index| {
        if (value == null) break index;
    } else return error.NoCounterController;
    const attacker_id = if (attacker < self.partyCount()) self.progress.party[attacker].id else self.enemy(attacker - self.partyCount()).id;
    const defender_id = if (defender < self.partyCount()) self.progress.party[defender].id else self.enemy(defender - self.partyCount()).id;
    const origin = packet.attackerFor(attacker_id, kind) orelse return error.MissingCounterProgram;
    const attacker_resource = packet.animations.find(origin.id) orelse return error.MissingActorResource;
    const defender_resource = packet.animations.find(defender_id) orelse return error.MissingActorResource;
    const responder = if (kind.ordinary()) null else packet.defenderFor(defender_id, kind) orelse return error.MissingCounterProgram;
    for ([_][]const u8{ origin.attack_program, origin.return_program }) |program| {
        try packet.validateProgram(program, attacker_resource);
        if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), attacker_resource, program, 0, 0, false);
    }
    if (kind == .projectile) {
        const child = packet.meleeEnemy(attacker_id).?.projectile.?;
        try packet.validateProgram(child.child_program, attacker_resource);
        if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), attacker_resource, child.child_program, child.animation, 0, true);
    }
    if (packet.cooperation) |binding| if (std.mem.eql(u8, binding.id, attacker_id)) {
        try packet.validateProgram(binding.fallback_program, attacker_resource);
        if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), attacker_resource, binding.fallback_program, 0, 0, false);
    };
    if (guard) |index| {
        const cover = packet.cover orelse return error.MissingCounterProgram;
        const resource = packet.animations.find(self.progress.party[index].id) orelse return error.MissingActorResource;
        const melee = packet.meleeEnemy(attacker_id) orelse return error.MissingCounterProgram;
        for ([_][]const u8{ cover.guard_program, melee.hurt_program }) |program| {
            try packet.validateProgram(program, resource);
            if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), resource, program, 0, 0, false);
        }
        for ([_][]const u8{ cover.ward_program, cover.return_program }) |program| {
            try packet.validateProgram(program, defender_resource);
            if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), defender_resource, program, 0, 0, false);
        }
    } else if (kind.party()) {
        const ranged = packet.partyAttacker(attacker_id, kind) orelse return error.MissingCounterProgram;
        const hurt = if (critical) ranged.critical_hurt_program orelse ranged.hurt_program else ranged.hurt_program;
        try packet.validateProgram(hurt, defender_resource);
        if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), defender_resource, hurt, 0, 0, false);
        if (kind.miss()) {
            const reaction = packet.rangedDodge(defender_id) orelse return error.MissingCounterProgram;
            try packet.validateProgram(reaction.response_program, defender_resource);
            if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), defender_resource, reaction.response_program, 0, 0, false);
        }
    } else if (kind.ordinary()) {
        const reaction = packet.partyReaction(defender_id) orelse return error.MissingCounterProgram;
        const melee = packet.meleeEnemy(attacker_id) orelse return error.MissingCounterProgram;
        const hurt = if (kind == .special) (melee.special orelse return error.MissingCounterProgram).hurt_program else melee.hurt_program;
        for ([_][]const u8{ reaction.response_program, hurt }) |program| {
            try packet.validateProgram(program, defender_resource);
            if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), defender_resource, program, 0, 0, false);
        }
    } else {
        try packet.validateProgram(responder.?.hurt_program, attacker_resource);
        if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), attacker_resource, responder.?.hurt_program, 0, 0, false);
        for ([_][]const u8{ responder.?.response_program, responder.?.strike_program }) |program| {
            try packet.validateProgram(program, defender_resource);
            if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), defender_resource, program, 0, 0, false);
        }
    }
    const victim = guard orelse if (kind.ordinary()) defender else attacker;
    if (victim >= self.partyCount()) {
        if ((self.uniteReactionPose(victim) orelse return error.MissingCounterKnockout).knockout == null) return error.MissingCounterKnockout;
    } else if (self.content.presentation_ready and self.partyProfile(victim).revival_art == null) return error.MissingCounterKnockout;
    self.unite_vm.auxiliary_capacity = @intCast(19 - self.partyCount() - self.enemyCount());
    const source_projectile = self.hasSourceRabbit(attacker) or (kind.ordinary() and attacker >= self.partyCount() and self.enemy(attacker - self.partyCount()).action_policy == .source_projectile);
    self.unite_vm.counter_actions[leader] = .{ .kind = kind, .attacker = @intCast(attacker), .defender = @intCast(defender), .guard = if (guard) |index| @intCast(index) else null, .critical = critical, .start_at = self.camera_ticks +% @intFromBool(!source_projectile) };
    self.active = .{ .actor = attacker, .target = defender, .kind = if (kind.miss() or !kind.ordinary()) .miss else .attack, .critical = critical, .enemy_special = kind == .special, .counter_attack = true };
}
pub fn prepareCounter(self: *State, leader: usize, runtime: *host.Runtime) !void {
    const bundle = self.unite_actors.?;
    const playback = &self.unite_vm.counter_actions[leader].?;
    const ids = [3]?u8{ playback.attacker, playback.defender, playback.guard };
    var positions: [3][3]i32 = undefined;
    for (ids, 0..) |maybe, index| if (maybe) |actor| {
        positions[index] = q12(layout.worldPosition(self, actor));
    };
    for (ids, 0..) |maybe, ordinal| {
        const actor = maybe orelse continue;
        const position = positions[ordinal];
        const id = if (actor < self.partyCount()) self.progress.party[actor].id else self.enemy(actor - self.partyCount()).id;
        const resource = for (bundle.animations.resources, 0..) |value, index| {
            if (std.mem.eql(u8, value.id, id)) break index;
        } else return error.MissingActorResource;
        try yieldReactionActor(self, actor);
        self.unite_vm.actors[actor] = try @import("battle_enemy_idle.zig").prepareActor(self, actor, bundle.animations.resources[resource], position);
        self.unite_vm.actors[actor].regional = bundle.regionalFor(id);
        self.unite_vm.scripted_actors[actor] = .{ .family = .counter, .leader = @intCast(leader), .resource = @intCast(resource) };
        self.unite_flags[actor] = 0;
    }
    playback.action = if (playback.guard) |guard| try battle.counter.Action.beginCovered(bundle.counterPacket().?, runtime, playback.attacker, playback.defender, guard) else try battle.counter.Action.beginFor(bundle.counterPacket().?, runtime, playback.attacker, playback.defender, playback.kind);
    playback.action.?.critical = playback.critical;
    if (playback.guard == null and playback.attacker >= self.partyCount()) if (runtime.actors[playback.attacker].regional) |regional| {
        if (playback.kind == .special or regional.direct_attack) {
            try playback.action.?.configureRegional(bundle.counterPacket().?, runtime, playback.defender, regional);
            if (regional.camera_shake_z_q12 != 0) {
                if (self.actor_camera == null) self.actor_camera = try @import("battle_camera").ActorController.init(layout.cameraForTransition(self));
                runtime.camera_controller = &self.actor_camera.?;
            }
        }
    };
    if (playback.kind == .projectile) if (bundle.counterPacket().?.meleeEnemy("killer_rabbit").?.projectile.?.camera) |request| {
        if (self.actor_camera == null) self.actor_camera = try @import("battle_camera").ActorController.init(layout.cameraForTransition(self));
        try self.actor_camera.?.requestQ12(request.target, request.updates);
        runtime.camera_controller = &self.actor_camera.?;
    };
}
pub fn applyCounterContact(self: *State, leader: usize) !void {
    const playback = &self.unite_vm.counter_actions[leader].?;
    const victim = playback.victim();
    const striker = playback.striker();
    const random = self.roll();
    if (self.replay_exhausted) return error.RandomInputExhausted;
    const defending = victim < self.partyCount() and self.actions[victim] != null and self.actions[victim].? == .defend;
    const base = self.resolvePhysicalDamage(striker, victim, random, defending);
    const amount = if (playback.kind == .special) blk: {
        const binding = self.unite_actors.?.counterPacket().?.meleeEnemy(self.enemy(striker - self.partyCount()).id).?.special.?;
        break :blk base * binding.damage_numerator / binding.damage_denominator;
    } else base * @as(u32, if (playback.critical) 3 else 1);
    playback.amount = if (playback.action != null and playback.action.?.regional_mode == .creeper_special) blk: {
        const hit_amount = if (self.actor_conditions[victim].protection_rounds == 0) amount else 0;
        const applied: u32 = if (self.hp(victim) == 0) 0 else hit_amount;
        if (victim < self.partyCount()) {
            self.progress.party[victim].hp = @intCast(@as(u32, self.hp(victim)) -| applied);
            if (self.hp(victim) == 0) self.markPartyKnockout(victim);
        } else self.enemy_hp[victim - self.partyCount()] = @intCast(@as(u32, self.hp(victim)) -| applied);
        break :blk playback.amount +| applied;
    } else blk: {
        const settled = if (self.actor_conditions[victim].protection_rounds == 0) amount else 0;
        if (victim < self.partyCount()) {
            self.progress.party[victim].hp = @intCast(@as(u32, self.hp(victim)) -| settled);
            if (self.hp(victim) == 0) self.markPartyKnockout(victim);
        } else self.enemy_hp[victim - self.partyCount()] = @intCast(@as(u32, self.hp(victim)) -| settled);
        break :blk settled;
    };
    playback.contact_at = self.camera_ticks;
    if (self.active) |*effect| if (effect.counter_attack and effect.actor == playback.attacker) {
        effect.amount = playback.amount;
        effect.affected |= @as(u16, 1) << @intCast(victim);
        effect.amounts[victim] = playback.amount;
    };
}
pub fn advanceCoverActor(self: *State, actor: usize) void {
    for (self.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
        if (playback.guard == null or playback.guard.? != actor or playback.contact_at == null) continue;
        const current = &self.unite_vm.actors[actor];
        if (current.highlights & 8 != 0) return;
        if (self.revivalAge(actor)) |age| {
            if (age < self.rules.automatic_revival.?.release_delay) current.highlights |= 1 else current.highlights &= ~@as(u8, 1);
        } else if (self.hp(actor) == 0 and self.party_knockouts[actor].pending and battle.revival.hasBuddha(self.*, actor)) {
            if (!self.commitPartyKnockout(actor)) current.highlights |= 1;
        }
        return;
    };
}
pub fn beginStrongArmCooperation(self: *State, actor: usize) !void {
    const packet = self.unite_actors.?.counterPacket().?;
    const binding = packet.cooperation orelse return error.MissingCounterProgram;
    if (actor < self.partyCount() or !std.mem.eql(u8, self.enemy(actor - self.partyCount()).id, binding.id)) return error.InvalidActorBinding;
    for (&self.unite_vm.counter_actions) |*maybe| if (maybe.*) |*playback| {
        if (playback.attacker != actor or playback.controller_done) continue;
        if (playback.cooperation.active or playback.cooperation.assistant != null) return error.ActorEffectAlreadyActive;
        playback.cooperation.active = true;
        return;
    };
    return error.MissingCounterProgram;
}
pub fn advanceStrongArmActor(self: *State, actor: usize, runtime: *host.Runtime) !void {
    const packet = self.unite_actors.?.counterPacket() orelse return;
    const binding = packet.cooperation orelse return;
    for (&self.unite_vm.counter_actions, 0..) |*maybe, leader| if (maybe.*) |*playback| {
        if (playback.attacker != actor or playback.action == null) continue;
        var candidate: ?u8 = null;
        if (playback.cooperation.active and runtime.actors[actor].shared_value == 0) {
            for (self.partyCount()..self.partyCount() + self.enemyCount()) |other| {
                if (other == actor or !self.participates(other) or runtime.actors[other].highlights != 0 or self.coordinatorLocked(other)) continue;
                if (self.unite_vm.ownsActor(other)) return error.ActorAlreadyOwned;
                const id = self.enemy(other - self.partyCount()).id;
                const allowed = for (binding.allies) |name| {
                    if (std.mem.eql(u8, id, name)) break true;
                } else false;
                if (!allowed) return error.MissingActorResource;
                const resource = packet.animations.find(id) orelse return error.MissingActorResource;
                inline for (.{ "approach_program", "lift_program", "launch_program" }) |name| {
                    const program = @field(binding, name);
                    try packet.validateProgram(program, resource);
                    if (self.content.presentation_ready) try art.checkProgramArt(self.*, packet.library(), resource, program, 0, 0, false);
                }
                const position = q12(layout.worldPosition(self, other));
                const resource_index = for (self.unite_actors.?.animations.resources, 0..) |value, index| {
                    if (std.mem.eql(u8, value.id, id)) break index;
                } else return error.MissingActorResource;
                runtime.actors[other] = try @import("battle_enemy_idle.zig").prepareActor(self, other, resource, position);
                self.unite_vm.scripted_actors[other] = .{ .family = .counter, .leader = @intCast(leader), .resource = @intCast(resource_index) };
                candidate = @intCast(other);
                break;
            }
        }
        try playback.cooperation.advance(binding, runtime, @intCast(actor), candidate);
        if (runtime.actors[actor].released) if (self.coordinator) |*clock| if (clock.current_actor == actor) {
            clock.completed = true;
        };
        return;
    };
}
pub fn releaseProjectileTurn(self: *State, actor: usize, runtime: *host.Runtime) void {
    if (actor < self.partyCount() or actor >= self.partyCount() + self.enemyCount()) return;
    if (!runtime.actors[actor].released) return;
    const clock = if (self.coordinator) |*value| value else null;
    if (clock) |value| if (value.current_actor != actor) return;
    for (self.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
        if (playback.attacker != actor or playback.controller_done or playback.action == null) continue;
        if (playback.kind != .projectile and self.enemy(actor - self.partyCount()).action_policy != .source_projectile) continue;
        if (playback.kind != .projectile and clock == null) return;
        if (clock) |value| value.completed = true;
        if (self.active) |effect| if (effect.counter_attack and effect.actor == actor) {
            self.active = null;
        };
        return;
    };
}
pub fn finishCounterController(self: *State, leader: usize) void {
    const playback = &self.unite_vm.counter_actions[leader].?;
    if (playback.controller_done) return;
    playback.controller_done = true;
    if (self.active) |effect| if (effect.counter_attack and effect.actor == playback.attacker) {
        self.active = null;
    };
    if (self.coordinator) |*clock| if (clock.current_actor == playback.attacker) {
        clock.completed = true;
    };
}
pub fn retainPosition(self: *State, actor: usize) void {
    const current = self.unite_vm.actors[actor];
    const home = self.uniteVmHome(actor);
    const transform = &self.actor_transforms[actor];
    transform.world_offset = .{
        .x = @as(f32, @floatFromInt(current.position_q12[0])) / 4096 - home.x,
        .y = @as(f32, @floatFromInt(current.position_q12[1])) / 4096 - home.y,
        .z = @as(f32, @floatFromInt(current.position_q12[2])) / 4096 - home.z,
    };
    if (self.content.world_art == null) transform.screen_offset = current.screen_offset;
    transform.node_angles = .{ 0, 0, 0 };
}
pub fn repeatCounter(self: *State, leader: usize, runtime: *host.Runtime) !bool {
    const playback = self.unite_vm.counter_actions[leader].?;
    if (playback.kind != .parry and !playback.kind.party()) return false;
    const enemy = self.nextDoubleBeatTarget(playback.attacker, playback.defender - self.partyCount()) orelse return false;
    const target = self.partyCount() + enemy;
    if (self.active) |effect| if (!effect.counter_attack and effect.actor != playback.attacker) return true;
    if (self.coordinatorLocked(target) or self.unite_vm.ownsActor(target)) {
        // The common return callback retries the selected busy target before accuracy or latch changes.
        return true;
    }
    const origin = self.unite_vm.actors[playback.attacker].position_q12;
    retainPosition(self, playback.attacker);
    self.unite_vm.scripted_actors[playback.attacker] = null;
    self.unite_vm.counter_actions[leader].?.attacker_done = true;
    self.finishCounterController(leader);
    if (playback.defender_done) self.unite_vm.counter_actions[leader] = null;
    self.beginAttack(playback.attacker, target, .{ .followup = playback.defender });
    if (self.replay_exhausted) return error.RandomInputExhausted;
    if (self.replay_unsupported != null) return error.UnsupportedCounterFollowup;
    if (self.active != null and !self.active.?.counter_attack) {
        self.active.?.motion_origin = .{ .x = @as(f32, @floatFromInt(origin[0])) / 4096, .y = @as(f32, @floatFromInt(origin[1])) / 4096, .z = @as(f32, @floatFromInt(origin[2])) / 4096 };
        self.actor_transforms[playback.attacker].world_offset = .{ .x = 0, .y = 0, .z = 0 };
    }
    if (self.coordinator != null) self.active.?.started_at = self.action_ticks else self.action_ticks = 0;
    if (self.active != null and self.active.?.counter_attack) for (&self.unite_vm.counter_actions, 0..) |*value, index| if (value.*) |*next| {
        if (next.attacker != playback.attacker or next.controller_done or next.action != null) continue;
        if (self.coordinator) |*clock| if (clock.current_actor == playback.attacker) {
            clock.completed = false;
        };
        next.start_at = self.camera_ticks;
        try self.prepareCounter(index, runtime);
    };
    return true;
}
pub fn finishCounterActors(self: *State) void {
    for (&self.unite_vm.counter_actions, 0..) |*maybe, leader| if (maybe.*) |*playback| {
        if (playback.action == null) continue;
        for ([4]?u8{ playback.attacker, playback.defender, playback.guard, playback.cooperation.assistant }, 0..) |maybe_actor, role| {
            const actor = maybe_actor orelse continue;
            if (playback.guard != null and actor == playback.defender and playback.contact_at == null) continue;
            const binding = self.unite_vm.scripted_actors[actor] orelse continue;
            if (binding.family != .counter or binding.leader != leader) continue;
            const current = &self.unite_vm.actors[actor];
            if (actor == playback.victim() and actor < self.partyCount() and self.hp(actor) == 0) {
                if (current.highlights != 0) continue;
            } else if (actor == playback.victim() and self.hp(actor) == 0) {
                if (playback.knockout_at == null) {
                    if (current.machine == null or !current.machine.?.halted or current.highlights != 0) continue;
                    playback.knockout_at = self.camera_ticks;
                }
                const ko = self.uniteReactionPose(actor).?.knockout.?;
                if (self.camera_ticks - playback.knockout_at.? < ko.duration) continue;
            } else if (current.machine == null or !current.machine.?.halted or current.highlights != 0) continue;
            if (playback.guard == actor and self.revivalAge(actor) != null) continue;
            if (self.unite_vm.actors[actor].suikomi_phase != null) continue;
            retainPosition(self, actor);
            if (actor < self.actor_transforms.len) self.actor_transforms[actor].scale_q12 = 4096;
            self.unite_vm.scripted_actors[actor] = null;
            if (role == 0) playback.attacker_done = true else if (role == 1) playback.defender_done = true else if (role == 2) playback.guard_done = true else playback.cooperation.assistant_done = true;
            if (actor < self.partyCount()) {
                if (self.hp(actor) == 0) _ = self.commitPartyKnockout(actor);
            } else self.dodge_idle_at[actor - self.partyCount()] = self.presentation_tick;
        }
        if (playback.controller_done and playback.attacker_done and playback.defender_done and (playback.guard == null or playback.guard_done) and (playback.cooperation.assistant == null or playback.cooperation.assistant_done)) maybe.* = null;
    };
}
pub fn holdRegionalDispatch(self: *State, actor: usize) !void {
    if (self.coordinator) |*clock| if (clock.current_actor == actor) {
        clock.cross_side_pending = true;
    };
}
pub fn dispatchPartyTailReturn(self: *State, actor: usize, runtime: *host.Runtime) !void {
    if (actor >= self.partyCount()) return error.InvalidActorBinding;
    const binding = self.unite_vm.scripted_actors[actor] orelse return error.InvalidActorBinding;
    if (binding.family != .counter) return error.InvalidActorBinding;
    const playback = self.unite_vm.counter_actions[binding.leader] orelse return error.InvalidActorBinding;
    const packet = (self.unite_actors orelse return error.MissingActorLibrary).counterPacket() orelse return error.MissingCounterProgram;
    const reaction = packet.partyReaction(self.progress.party[actor].id) orelse return error.InvalidCounterBindings;
    const ret = reaction.return_program orelse return error.InvalidCounterBindings;
    try runtime.dispatch(@intCast(actor), playback.attacker, packet.programs.find(ret).?);
}
pub fn syncRegionalActorVisuals(self: *State, actor: usize, runtime: *const host.Runtime) void {
    if (actor >= self.partyCount() + self.enemyCount()) return;
    for (self.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
        if (playback.action) |action| if (action.regional_mode == .creeper_special and playback.defender == actor) {
            const current = runtime.actors[actor];
            if (current.suikomi_phase != null or self.actor_transforms[actor].scale_q12 != current.draw_size_q12) {
                self.actor_transforms[actor].scale_q12 = current.draw_size_q12;
                self.actor_transforms[actor].node_angles = current.draw_angles;
            }
            return;
        };
    };
}
