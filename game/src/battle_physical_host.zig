const std = @import("std");
const battle = @import("battle.zig");
const physical = @import("battle_physical.zig");
const host = @import("battle_actor_host.zig");
const layout = @import("battle_layout.zig");
const State = battle.State;

pub fn sourcePhysicalRuneOwner(self: *const State, owner: usize) bool {
    return owner < self.unite_vm.physical_actions.len and self.unite_vm.physical_actions[owner] != null;
}
pub fn beginSourcePhysicalRune(self: *State, owner: usize, recipient: usize) !void {
    const bundle = self.unite_actors orelse return error.MissingActorLibrary;
    const packet = bundle.physicalPacket() orelse return error.MissingActorLibrary;
    const technique = @import("battle_systems").techniques.physical.techniqueForRune(self.runeByteFor(owner) orelse return error.InvalidPhysicalMember) orelse return error.InvalidPhysicalMember;
    if (owner >= self.partyCount() or recipient < self.partyCount() or recipient >= self.partyCount() + self.enemyCount() or self.sourcePhysicalRuneOwner(owner) or self.unite_vm.ownsActor(owner) or self.unite_vm.ownsActor(recipient)) return error.ActorAlreadyOwned;
    const binding = packet.find(technique).?;
    var allowed = false;
    for (binding.members) |id| allowed = allowed or std.mem.eql(u8, id, self.progress.party[owner].id);
    if (!allowed) return error.InvalidPhysicalMember;
    const resource = bundle.animations.find(self.progress.party[owner].id) orelse return error.MissingActorResource;
    const target = bundle.animations.find(self.enemy(recipient - self.partyCount()).id) orelse return error.MissingActorResource;
    try packet.validateProgram(binding.owner_program, resource);
    try packet.validateProgram(binding.recipient_program, target);
    if (self.content.presentation_ready) {
        try checkProgramArt(self.*, packet.library(), resource, binding.owner_program, 0, 0, false);
        try checkProgramArt(self.*, packet.library(), target, binding.recipient_program, 0, 0, false);
        if (binding.auxiliary) |child| try checkProgramArt(self.*, packet.library(), packet.animations.find(child.resource).?, child.program, child.animation, 0, false);
    }
    const pose = self.uniteReactionPose(recipient) orelse return error.MissingPhysicalKnockout;
    if (pose.knockout == null) return error.MissingPhysicalKnockout;
    self.unite_vm.auxiliary_capacity = @intCast(19 - self.partyCount() - self.enemyCount());
    self.unite_vm.physical_actions[owner] = .{ .technique = technique, .owner = @intCast(owner), .recipient = @intCast(recipient), .start_at = self.camera_ticks +% 1 };
    self.active = .{ .actor = owner, .target = recipient, .kind = .attack, .rune_attack = true };
}
pub fn preparePhysicalRune(self: *State, owner: usize, runtime: *host.Runtime) !void {
    const bundle = self.unite_actors.?;
    const packet = bundle.physicalPacket().?;
    const playback = &self.unite_vm.physical_actions[owner].?;
    const ids = [2]usize{ owner, playback.recipient };
    var positions: [2][3]i32 = undefined;
    for (ids, 0..) |actor, ordinal| positions[ordinal] = layout.worldPosition(self, actor).toQ12Rounded();
    for (ids, positions) |actor, position| {
        const id = if (actor < self.partyCount()) self.progress.party[actor].id else self.enemy(actor - self.partyCount()).id;
        const index = for (bundle.animations.resources, 0..) |resource, index| {
            if (std.mem.eql(u8, resource.id, id)) break index;
        } else return error.MissingActorResource;
        self.unite_vm.actors[actor] = try @import("battle_enemy_idle.zig").prepareActor(self, actor, bundle.animations.resources[index], position);
        self.unite_vm.scripted_actors[actor] = .{ .leader = @intCast(owner), .resource = @intCast(index) };
        self.unite_flags[actor] = 0;
    }
    if (self.actor_camera == null) self.actor_camera = try @import("battle_camera").ActorController.init(layout.cameraForTransition(self));
    runtime.camera_controller = &self.actor_camera.?;
    playback.action = try physical.Action.begin(packet, runtime, playback.technique, playback.owner, playback.recipient);
    if (playback.technique != .hate) self.physical_numerator = packet.find(playback.technique).?.numerator;
}
pub fn advancePhysicalRunes(self: *State) void {
    self.unite_vm.advancePhysical(self, layout.cameraForTransition(self)) catch |err| {
        if (err == error.RandomInputExhausted) self.replay_exhausted = true else self.replay_unsupported = .coordinator_action;
    };
}
pub fn finishPhysicalRuneController(self: *State, owner: usize) void {
    if (self.active) |effect| if (effect.rune_attack and effect.actor == owner) {
        self.active = null;
        if (self.coordinator) |*clock| if (clock.current_actor == owner) {
            clock.completed = true;
        };
    };
}
pub fn applyPhysicalRuneContact(self: *State, owner: usize) !void {
    const playback = &self.unite_vm.physical_actions[owner].?;
    const recipient = playback.recipient;
    const roll = self.roll();
    if (self.replay_exhausted) return error.RandomInputExhausted;
    const base = self.resolvePhysicalDamage(owner, recipient, roll, false);
    const amount = @import("battle_systems").techniques.physical.damage(self.physical_numerator, base);
    playback.amount = if (self.actor_conditions[recipient].protection_rounds == 0) amount else 0;
    if (self.actor_conditions[recipient].protection_rounds == 0) {
        self.enemy_hp[recipient - self.partyCount()] = @intCast(@as(u32, self.enemy_hp[recipient - self.partyCount()]) -| amount);
    }
    if (self.active) |*effect| if (effect.rune_attack and effect.actor == owner) {
        effect.amount = playback.amount;
        effect.affected |= @as(u16, 1) << @intCast(recipient);
        effect.amounts[recipient] = playback.amount;
    };
}
pub fn finishPhysicalRuneActors(self: *State) void {
    for (&self.unite_vm.physical_actions, 0..) |*maybe, leader| if (maybe.*) |*playback| {
        if (playback.action == null) continue;
        for ([2]u8{ playback.owner, playback.recipient }, 0..) |actor, role| {
            const binding = self.unite_vm.scripted_actors[actor] orelse continue;
            if (binding.family != .physical or binding.leader != leader) continue;
            const current = &self.unite_vm.actors[actor];
            self.actor_transforms[actor].node_angles = current.draw_angles;
            if (current.machine == null or !current.machine.?.halted or current.highlights != 0 or (role == 1 and playback.action.?.damage_pending)) continue;
            if (role == 1 and self.hp(actor) == 0) {
                if (playback.knockout_at == null) playback.knockout_at = self.camera_ticks;
                const ko = self.uniteReactionPose(actor).?.knockout.?;
                if (self.camera_ticks - playback.knockout_at.? < ko.duration) continue;
            }
            const home = self.uniteVmHome(actor);
            const position = battle.Position.fromQ12(current.position_q12);
            self.actor_transforms[actor].world_offset = .{ .x = position.x - home.x, .y = position.y - home.y, .z = position.z - home.z };
            if (self.content.world_art == null) self.actor_transforms[actor].screen_offset = current.screen_offset;
            self.unite_vm.scripted_actors[actor] = null;
            self.actor_transforms[actor].node_angles = .{ 0, 0, 0 };
            if (role == 0) playback.owner_done = true else {
                playback.recipient_done = true;
                self.dodge_idle_at[actor - self.partyCount()] = self.presentation_tick;
            }
        }
        if (playback.owner_done and playback.recipient_done and playback.action.?.stage == .released) maybe.* = null;
    };
}
fn resourcePose(self: State, resource: host.Resource, pose: u16) ?battle.Pose {
    if (self.content.uniteGraphic(resource.id, pose)) |sprite| return sprite;
    if (self.content.world_art) |art| for (art.actors) |actor| {
        if (std.mem.eql(u8, actor.id, resource.id) and pose < actor.poses.len) return actor.poses[pose];
    };
    const profile = self.content.partyProfile(resource.id) orelse if (self.content.enemyIndex(resource.id)) |index| self.content.enemies[index] else return null;
    if (pose == resource.find(0).?.frames[0].pose) return profile.sprite;
    for (profile.attack) |frame| if (frame.source_pose == pose) return frame.pose;
    for (profile.cast) |frame| if (frame.source_pose == pose) return frame.pose;
    if (profile.revival_art) |art| for ([_][]const battle.Frame{ art.down.frames, art.recovery.frames }) |frames| for (frames) |frame| {
        if (frame.source_pose == pose) return frame.pose;
    };
    return null;
}
pub fn physicalRunePose(self: State, actor: usize) ?battle.Pose {
    if (actor >= self.unite_vm.scripted_actors.len or (self.unite_vm.scripted_actors[actor] == null and self.unite_vm.idle[actor] == null)) return null;
    const current = self.unite_vm.actors[actor];
    const resource = current.resource.?;
    const pose = current.currentFrame().pose;
    if (current.palette == .shared and current.palette.shared == 0) if (self.content.uniteWhiteGraphic(resource.id, pose)) |white| return white;
    if (self.content.ordinaryActorGraphic(resource.id, pose)) |ordinary| return ordinary;
    return resourcePose(self, resource, pose);
}
pub fn physicalRuneReaction(self: State, actor: usize) ?battle.spell_scene.ReactionSample {
    if (actor >= self.unite_vm.scripted_actors.len) return null;
    const binding = self.unite_vm.scripted_actors[actor] orelse return null;
    if (actor < self.partyCount() and binding.family != .enemy_magic) return null;
    const knockout_at = switch (binding.family) {
        .physical => self.unite_vm.physical_actions[binding.leader].?.knockout_at,
        .counter => self.unite_vm.counter_actions[binding.leader].?.knockout_at,
        .enemy_magic, .commander, .enemy_wave => null,
    };
    const pose = self.uniteReactionPose(actor) orelse return null;
    if (knockout_at) |at| return battle.spell_scene.knockoutAfterHurt(pose, @intCast(self.camera_ticks - at));
    const current = self.unite_vm.actors[actor];
    if (current.animation == 0) {
        if (current.palette == .shared) switch (current.palette.shared) {
            1...3 => if (pose.idle_flash) |idle| if (current.frame < idle.frames.len) {
                return .{ .animation = 0, .entry = idle.frames[current.frame].entries[current.palette.shared - 1], .offset = .{ 0, 0 } };
            },
            else => {},
        };
        return null;
    }
    if (current.animation != 1) return null;
    const entry = if (current.palette == .shared) switch (current.palette.shared) {
        0 => pose.white_entry orelse pose.entry,
        1...3 => if (pose.flash_entries) |variants| variants[current.palette.shared - 1] else pose.entry,
        4...6 => if (pose.shock_entries) |variants| variants[current.palette.shared - 4] else pose.entry,
        else => pose.entry,
    } else pose.entry;
    return .{ .entry = entry, .offset = .{ 0, 0 } };
}
pub fn checkProgramArt(self: State, library: host.Library, resource: host.Resource, program: []const u8, initial_animation: u16, depth: u8, secondary: bool) !void {
    if (depth >= 19) return error.InvalidPhysicalBindings;
    var animation = initial_animation;
    try checkClipArt(self, resource, animation, secondary);
    for (library.programs.find(program).?.instructions) |instruction| if (instruction == .command) switch (instruction.command) {
        .animation => |id| {
            animation = id;
            try checkClipArt(self, resource, id, secondary);
        },
        .child => |child| try checkProgramArt(self, library, library.resources.find(child.resource).?, child.program, child.animation, depth + 1, child.draw_record),
        .effect => |effect| if (std.mem.eql(u8, effect.id, "blue_afterimages")) {
            const pose = resource.find(animation).?.frames[0].pose;
            const found = search: for (self.content.unite_graphics) |graphic| {
                if (graphic.record != null or !std.mem.eql(u8, graphic.id, resource.id)) continue;
                for (graphic.poses) |entry| if (entry.id == pose and entry.trail != null) break :search true;
            } else false;
            if (!found) return error.MissingPhysicalArt;
        },
        else => {},
    };
}
fn checkClipArt(self: State, resource: host.Resource, animation: u16, secondary: bool) !void {
    if (std.mem.eql(u8, resource.id, "shared_impacts")) {
        const packet = self.spell_scenes orelse return error.MissingPhysicalArt;
        for (packet.unite_impacts) |clip| if (clip.id == animation) return;
        return error.MissingPhysicalArt;
    }
    if (animation == 1 and self.content.enemyIndex(resource.id) != null) {
        if (self.spell_scenes) |packet| for (packet.hurt_poses) |pose| if (std.mem.eql(u8, resource.id, pose.id)) return;
    }
    if (secondary) for (resource.find(animation).?.frames) |frame| {
        const found = search: for (self.content.unite_graphics) |graphic| {
            if (graphic.record != null or !std.mem.eql(u8, graphic.id, resource.id)) continue;
            for (graphic.poses) |pose| if (pose.id == frame.pose and pose.pieces.len != 0) break :search true;
        } else false;
        if (!found) return error.MissingPhysicalArt;
    };
    for (resource.find(animation).?.frames) |frame| if (resourcePose(self, resource, frame.pose) == null) return error.MissingPhysicalArt;
}
