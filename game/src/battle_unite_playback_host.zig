const actor_host = @import("battle_actor_host.zig");
const std = @import("std");
const status = @import("battle_status.zig");
const battle_systems = @import("battle_systems");
const unite_systems = battle_systems.unite;
const layout = @import("battle_layout.zig");
const drops = @import("battle_drops.zig");
const spell_scene = @import("battle_spell_scene.zig");
const systems = @import("battle_rules");
const battle = @import("battle.zig");
const types_mod = @import("battle_types.zig");
const unite_host_mod = @import("battle_unite_host.zig");
const State = battle.State;
const Pose = types_mod.Pose;
const Position = types_mod.Position;
const UniteTrack = types_mod.UniteTrack;
const Profile = types_mod.Profile;
const UniteReturn = types_mod.UniteReturn;
const UniteContext = unite_host_mod.UniteContext;
const uniteHost = unite_host_mod.uniteHost;

pub fn enemyCount(self: *const State) usize {
    return self.content.encounters[self.encounter].enemies.len;
}
pub fn enemy(self: *const State, index: usize) Profile {
    return self.content.enemies[self.content.enemyIndex(self.content.encounters[self.encounter].enemies[index]).?];
}
pub fn name(self: *const State, index: usize) []const u8 {
    return if (index < self.partyCount()) self.progress.party[index].name else self.enemy(index - self.partyCount()).name;
}
pub fn hp(self: *const State, index: usize) u16 {
    return if (index < self.partyCount()) self.progress.party[index].hp else self.enemy_hp[index - self.partyCount()];
}
pub fn participates(self: *const State, index: usize) bool {
    return self.hp(index) > 0 and (index >= self.partyCount() or !self.departed[index]);
}
pub fn isActing(self: *const State, member: usize) bool {
    if (self.uniteReturnFor(member) != null) return true;
    for (self.front_projectiles) |maybe| if (maybe) |shot| if (shot.actor == member and !shot.owner_released) return true;
    if (self.medicine_action) |item| if (item.actor == member and !item.owner_released) return true;
    if (member < self.partyCount()) if (self.party_strikes[member]) |strike| return !strike.owner_released;
    if (self.active == null) return false;
    const effect = &self.active.?;
    if ((effect.kind == .status_attack or effect.kind == .group_order) and effect.actor == member) return !effect.owner_released;
    if (effect.ordered) |child| if (child.actor == member) return child.started;
    if (effect.kind == .unite) {
        return self.activeUniteMember(member);
    }
    return effect.actor == member;
}
pub fn activeUniteMember(self: *const State, member: usize) bool {
    if (self.active == null) return false;
    const effect = &self.active.?;
    if (effect.kind != .unite) return false;
    if (self.activeUniteBoundary()) |boundary| {
        for (boundary.participantsSlice(), 0..) |participant, ordinal| if (participant == member) return boundary.finished_members & (@as(u8, 1) << @intCast(ordinal)) == 0;
        return false;
    }
    return effect.actor == member or effect.partner == member;
}
pub fn uniteMemberWaiting(self: *const State, member: usize) bool {
    if (self.unite_vm.owns(member)) return !self.unite_vm.members[member].?.initialized;
    if (!self.activeUniteMember(member)) return false;
    if (self.coordinator != null and self.effectTicks() == 0) return true;
    const track = self.uniteTrack(member) orelse return false;
    return self.effectTicks() < track.start_after;
}
pub fn memberImpact(self: *const State, member: usize) u16 {
    if (self.active) |effect| if (effect.damage_at_impact and effect.actor == member) return if (effect.projectile) self.enemy(member - self.partyCount()).projectile.?.impact_tick else self.enemy(member - self.partyCount()).ordinary_timing.?.impact_tick;
    if (self.actionMotion(member)) |motion| return motion.impact_tick;
    return 20;
}
pub fn hasUniteTracks(self: *const State) bool {
    const effect = self.active orelse return false;
    if (effect.kind != .unite or self.uniteTrack(effect.actor) == null) return false;
    if (self.activeUniteBoundary()) |boundary| {
        if (boundary.sequence != null) return false;
        for (boundary.participantsSlice()) |participant| if (self.uniteTrack(participant) == null) return false;
        return true;
    }
    const partner = effect.partner orelse return false;
    return self.uniteTrack(partner) != null;
}
pub fn uniteTrack(self: *const State, member: usize) ?UniteTrack {
    if (member >= self.partyCount()) return null;
    const profile = self.partyProfile(member);
    if (self.uniteReturnFor(member)) |tail| return profile.uniteTrack(tail.record);
    if (self.activeUniteBoundary()) |boundary| return profile.uniteTrack(boundary.record_index);
    return profile.uniteTrack(null);
}
pub fn uniteTargetReleaseTick(self: *const State) ?u16 {
    if (self.activeUniteBoundary()) |boundary| if (boundary.sequence != null) return null;
    if (self.hasLiveUniteActors() and self.unite_vm.impact_at[self.active.?.actor] == null) return null;
    if (!self.hasLiveUniteActors() and !self.hasUniteTracks()) return null;
    const boundary = self.activeUniteBoundary() orelse return null;
    const host = self.integrationHost() orelse return null;
    const record = host.uniteCatalogue().recordAt(boundary.record_index) orelse return null;
    const updates = record.target_reaction_updates orelse return null;
    return self.impactTick() + updates - 1;
}
pub fn advanceActorCamera(self: *State) void {
    if (self.actor_camera) |*controller| controller.advance();
}
pub fn issueUniteCameraRequests(self: *State, elapsed: u16) void {
    if (self.hasLiveUniteActors()) return;
    if (!self.hasUniteTracks()) return;
    for (0..self.partyCount()) |member| {
        if (!self.activeUniteMember(member)) continue;
        for (self.uniteTrack(member).?.camera) |request| {
            if (request.at + self.uniteTrack(member).?.start_after != elapsed) continue;
            const anchor = switch (request.binding) {
                .absolute => Position{ .x = 0, .y = 0, .z = 0 },
                .actor => layout.worldPosition(self, member),
                .target => layout.worldPosition(self, self.active.?.target),
            };
            if (self.actor_camera == null) self.actor_camera = @import("battle_camera").ActorController.init(layout.cameraForTransition(self)) catch {
                self.replay_unsupported = .coordinator_action;
                return;
            };
            self.actor_camera.?.request(request, anchor.toQ12Rounded()) catch {
                self.replay_unsupported = .coordinator_action;
                return;
            };
        }
    }
}
pub fn uniteHandoffTick(self: *const State) ?u16 {
    if (self.trick_wave) |wave| if (self.active != null and wave.owner == self.active.?.actor) return if (wave.wave.finished) self.effectTicks() else null;
    if (self.martial_queue) |queue| return if (queue.queue.finished) self.effectTicks() else null;
    if (self.hasLiveUniteActors()) {
        if (self.activeUniteBoundary()) |boundary| if (boundary.sequence) |sequence| {
            const finish = sequence.finish_at orelse return null;
            return if (self.effectTicks() >= finish) self.effectTicks() else null;
        };
        if (self.unite_scene) |scene| {
            const spec = self.unite_actors.?.find(scene.record).?.controller.?;
            if (spec.mode == .owner_clock and (self.active.?.scene == null or self.active.?.scene.?.elapsed < spec.return_at.?)) return null;
        }
        return if (self.unite_vm.allReady(self.active.?.actor)) self.effectTicks() else null;
    }
    if (!self.hasUniteTracks()) return null;
    const boundary = self.activeUniteBoundary() orelse return null;
    var handoff: u16 = 0;
    for (boundary.participantsSlice()) |participant| {
        const ready = self.uniteTrack(participant).?.motion.ready_tick orelse return null;
        handoff = @max(handoff, self.uniteTrack(participant).?.start_after + ready + 1);
    }
    return handoff;
}
pub fn uniteReturnFor(self: *const State, member: usize) ?UniteReturn {
    return if (member < self.partyCount()) self.unite_returns[member] else null;
}
pub fn hasUniteReturns(self: *const State) bool {
    if (self.unite_vm.hasCommander()) return true;
    if (self.unite_vm.hasEnemyWave()) return true;
    if (self.unite_vm.hasPhysical()) return true;
    if (self.unite_vm.hasCounter()) return true;
    if (self.unite_vm.hasEnemyMagic()) return true;
    for (self.unite_returns) |tail| if (tail != null) return true;
    for (0..self.partyCount() + self.enemyCount()) |actor| if (self.unite_reactions[actor] != null and self.uniteRecipientLocked(actor)) return true;
    return false;
}
pub fn handoffUnite(self: *State) void {
    if (self.martial_queue) |queue| {
        if (!queue.queue.finished) return;
        self.finishUnite();
        for (&self.unite_vm.members) |*member| if (member.* != null and member.*.?.leader == queue.owner) {
            member.* = null;
        };
        self.martial_queue = null;
        return;
    }
    const effect = self.active.?;
    const boundary = self.activeUniteBoundary().?;
    const target_release = self.uniteTargetReleaseTick();
    for (boundary.participantsSlice(), 0..) |participant, ordinal| {
        if (boundary.finished_members & (@as(u8, 1) << @intCast(ordinal)) != 0) continue;
        self.unite_returns[participant] = .{
            .record = boundary.record_index,
            .owner = effect.actor,
            .target = effect.target,
            .target_released = effect.target_released,
            .ticks = self.effectTicks(),
            .target_release = target_release,
            .handoff_at = self.camera_ticks,
        };
    }
}
pub fn advanceActiveUniteReturns(self: *State) void {
    if (!self.hasUniteTracks()) return;
    const owner = self.active.?.actor;
    const boundary = self.activeUniteBoundary() orelse return;
    for (boundary.participantsSlice(), 0..) |member, ordinal| {
        if (boundary.finished_members & (@as(u8, 1) << @intCast(ordinal)) != 0) continue;
        if (self.unite_vm.owns(member)) continue;
        if (self.effectTicks() >= self.uniteTrack(member).?.start_after + self.uniteTrack(member).?.motion.duration) self.finishUniteMember(owner, member);
        if (self.replay_unsupported != null) return;
    }
}
pub fn advanceUniteReturns(self: *State) void {
    for (0..self.partyCount()) |member| self.advanceUniteReturn(member);
}
pub fn advanceUniteReturn(self: *State, member: usize) void {
    const tail = if (self.unite_returns[member]) |*value| value else return;
    if (tail.handoff_at == self.camera_ticks) return;
    tail.ticks += 1;
    if (tail.target_release) |release| if (tail.ticks >= release and self.hp(tail.target) > 0) {
        tail.target_released = true;
    };
    if (self.unite_vm.owns(member)) return;
    if (tail.ticks < self.uniteTrack(member).?.start_after + self.uniteTrack(member).?.motion.duration) return;
    const owner = tail.owner;
    self.finishUniteMember(owner, member);
    if (self.replay_unsupported == null) self.unite_returns[member] = null;
}
pub fn finishUniteMember(self: *State, owner: usize, member: usize) void {
    if (self.martial_queue) |queue| if (queue.owner == owner) return;
    const boundary = if (self.unite_boundaries[owner]) |*value| value else {
        self.replay_unsupported = .coordinator_action;
        return;
    };
    var party_slots: [6]unite_systems.Slot = undefined;
    var enemy_slots: [6]unite_systems.Slot = undefined;
    const view = self.uniteView(&party_slots, &enemy_slots);
    var ctx = UniteContext{ .state = self, .boundary = boundary, .leader = owner, .target_enemy = 0 };
    boundary.finishMember(view, uniteHost(&ctx), member) catch {
        self.replay_unsupported = .coordinator_action;
        return;
    };
    if (boundary.stage == .finished) self.unite_boundaries[owner] = null;
}
pub fn memberDuration(self: *const State, member: usize) u16 {
    if (self.active) |effect| if (effect.damage_at_impact and effect.actor == member) return if (effect.projectile) self.enemy(member - self.partyCount()).projectile.?.duration else self.coverDuration(effect);
    if (self.actionMotion(member)) |motion| return motion.duration;
    return 52;
}
pub fn hasDrops(self: *const State) bool {
    return if (self.active) |*effect| effect.drops != null else false;
}
pub fn dropsFrame(self: *const State) drops.Frame {
    const instance = self.active.?.drops.?;
    return drops.frameWithCamera(self.drops_art.?, self.effectTicks(), instance.draws, instance.caster, instance.target, layout.currentCamera(self.*));
}
pub fn hasLiveUniteActors(self: *const State) bool {
    const effect = self.active orelse return false;
    if (effect.kind != .unite) return false;
    for (self.unite_vm.members) |maybe| if (maybe) |member| {
        if (member.leader == effect.actor) return true;
    };
    return false;
}
pub fn uniteProgramPose(self: *const State, member: usize, record: u8, pose: u16) ?Pose {
    if (member >= self.partyCount()) return null;
    const profile = self.partyProfile(member);
    if (self.content.uniteGraphicPose(profile.id, pose, record)) |graphic| return graphic.sprite;
    if (self.content.world_art) |art| {
        if (member >= art.actors.len or !std.mem.eql(u8, art.actors[member].id, profile.id) or pose >= art.actors[member].poses.len) return null;
        return art.actors[member].poses[pose];
    }
    const track = profile.uniteTrack(record) orelse return null;
    for (track.attack) |frame| if (frame.source_pose == pose) return frame.pose;
    return if (pose == 0) profile.sprite else null;
}
pub fn uniteVmPose(self: *const State, member: usize) ?Pose {
    if (member < self.unite_vm.scripted_actors.len and (self.unite_vm.scripted_actors[member] != null or self.unite_vm.idle[member] != null)) return self.physicalRunePose(member);
    const pose = self.unite_vm.pose(member) orelse return null;
    const palette = self.unite_vm.actors[member].palette;
    const record = self.unite_vm.members[member].?.record;
    if (palette == .shared and palette.shared == 0) return (self.content.uniteGraphicPose(self.progress.party[member].id, pose, record) orelse return null).white;
    if (palette == .shared and palette.shared >= 1 and palette.shared <= 3) {
        const variants = (self.content.uniteGraphicPose(self.progress.party[member].id, pose, record) orelse return null).flash orelse return null;
        return variants[palette.shared - 1];
    }
    return self.uniteProgramPose(member, self.unite_vm.members[member].?.record, pose);
}
pub fn uniteVmHome(self: *const State, actor: usize) Position {
    if (self.content.world_art) |art| return if (actor < self.partyCount()) art.formation_slots[self.formationSlot(actor)] else art.enemy_positions[actor - self.partyCount()];
    return layout.homePosition(self, actor);
}
pub fn beginUniteActors(self: *State, record: u8, leader: usize, target: usize) !void {
    const bundle = self.unite_actors.?;
    const binding = bundle.find(record) orelse return error.InvalidUniteBindings;
    if (binding.beat_child) |child| {
        const pose = self.uniteReactionPose(target) orelse return error.InvalidUniteSceneBinding;
        if (pose.source_attachment == null or !self.hasUniteReactionBinding(record, 1, target) or !self.hasUniteReactionBinding(record, 0, target)) return error.InvalidUniteSceneBinding;
        const resource = bundle.animations.find(child.resource).?;
        try checkChildClip(self, resource, child.animation, child.draw_record, record);
        const frozen = resource.find(child.animation).?.frames[0].pose;
        if ((self.content.uniteGraphicPose(child.resource, frozen, record) orelse return error.MissingUniteActorArt).trail == null) return error.MissingUniteActorArt;
    }
    if (binding.wave_heights != null) {
        if ((self.trick_wave != null and !self.trick_wave.?.wave.finished) or self.martial_queue != null or self.unite_scene != null or self.hasSpellScene() or self.hasDrops()) return error.InvalidUniteSceneBinding;
        for (self.partyCount()..self.partyCount() + self.enemyCount()) |recipient| if (self.hp(recipient) > 0 and !self.hasUniteReactionBinding(record, 0, recipient)) return error.InvalidUniteSceneBinding;
        const resource = bundle.animations.find(binding.members[1].id).?;
        for (resource.find(19).?.frames) |frame| if (self.content.uniteGraphicPose(resource.id, frame.pose, record) == null) return error.MissingUniteActorArt;
    }
    if (binding.target_queue != null) {
        if (self.martial_queue != null or self.hasSpellScene() or self.hasDrops()) return error.InvalidUniteSceneBinding;
        for (self.partyCount()..self.partyCount() + self.enemyCount()) |recipient| if (self.hp(recipient) > 0) {
            if (!self.hasUniteReactionBinding(record, 1, recipient) or !self.hasUniteReactionBinding(record, 2, recipient)) return error.InvalidUniteSceneBinding;
        };
    }
    if (binding.impact_effect) |id| {
        const packet = self.spell_scenes orelse return error.MissingUniteScene;
        const found = for (packet.unite_impacts) |clip| {
            if (clip.id == id) break true;
        } else false;
        if (!found) return error.MissingUniteScene;
    }
    if (binding.controller) |spec| {
        const packet = self.spell_scenes orelse return error.MissingUniteScene;
        const index = packet.uniteIndexOf(spec.vfx) orelse return error.MissingUniteScene;
        const program = packet.unite_scenes[index].program.?;
        if (self.unite_scene != null or self.hasSpellScene() or self.hasDrops() or program.duration != spec.cleanup_at or program.impact != spec.damage_at) return error.InvalidUniteSceneBinding;
        if (spec.mode == .beauty) {
            if (program.cameras.len != 1 or program.cameras[0].at != 2) return error.InvalidUniteSceneBinding;
            for (self.partyCount()..self.partyCount() + self.enemyCount()) |recipient| if (self.hp(recipient) > 0 and !self.hasUniteReactionBinding(record, spec.recipient_variant, recipient)) return error.InvalidUniteSceneBinding;
        } else if (program.group or program.cameras.len != 0 or !self.hasUniteReactionBinding(record, if (spec.mode == .orbit) spec.recipient_variant else 0, target)) return error.InvalidUniteSceneBinding;
    }
    for (binding.members) |member| {
        const slot = for (self.progress.party, 0..) |party, index| {
            if (std.mem.eql(u8, party.id, member.id)) break index;
        } else return error.MissingUniteParticipant;
        // shortcut: rotated Master–Pupil and Kai Flash bodies need the rotated packet footprint.
        if ((record == 31 or (record == 10 and std.mem.eql(u8, member.id, "kai"))) and !std.mem.eql(i16, &self.actor_transforms[slot].node_angles, &.{ 0, 0, 0 })) return error.InvalidActorBinding;
        const resource = bundle.animations.find(member.id).?;
        if (member.fan) |fan| if (self.content.uniteGraphicPose(member.id, resource.find(fan.animation).?.frames[0].pose, record) == null) return error.MissingUniteActorArt;
        var programs: [9][]const u8 = undefined;
        @memcpy(programs[0..member.programs.len], member.programs);
        var count = member.programs.len;
        if (binding.return_program) |id| {
            programs[count] = id;
            count += 1;
        }
        var needs_white = false;
        var needs_flash = false;
        for (programs[0..count]) |id| for (bundle.programs.find(id).?.instructions) |instruction| {
            if (instruction == .command and instruction.command == .reset_draw and !instruction.command.reset_draw) needs_white = true;
            if (instruction == .command and instruction.command == .palette_cycle) {
                if (!std.mem.eql(u8, &instruction.command.palette_cycle.variants, &.{ 1, 2, 3 })) return error.MissingUniteActorArt;
                needs_flash = true;
            }
        };
        for (programs[0..count]) |id| {
            for (bundle.programs.find(id).?.instructions) |instruction| {
                if (instruction == .command and instruction.command == .animation) {
                    for (resource.find(instruction.command.animation).?.frames) |frame| {
                        if (self.uniteProgramPose(slot, record, frame.pose) == null or (needs_white and (self.content.uniteGraphicPose(member.id, frame.pose, record) orelse return error.MissingUniteActorArt).white == null)) return error.MissingUniteActorArt;
                        if (needs_flash and (self.content.uniteGraphicPose(member.id, frame.pose, record) orelse return error.MissingUniteActorArt).flash == null) return error.MissingUniteActorArt;
                    }
                }
                if (instruction == .command and instruction.command == .child) {
                    const child = instruction.command.child;
                    const child_resource = bundle.animations.find(child.resource).?;
                    try checkChildClip(self, child_resource, child.animation, child.draw_record, record);
                    for (bundle.programs.find(child.program).?.instructions) |operation| {
                        if (operation == .command and operation.command == .animation) try checkChildClip(self, child_resource, operation.command.animation, child.draw_record, record);
                    }
                }
            }
        }
    }
    var party_ids: [6][]const u8 = undefined;
    var homes: [12][3]i32 = undefined;
    for (self.progress.party, 0..) |member, index| party_ids[index] = member.id;
    const count = self.partyCount() + self.enemyCount();
    for (0..count) |actor| {
        const home = self.uniteVmHome(actor);
        homes[actor] = home.toQ12Rounded();
    }
    try self.unite_vm.begin(bundle, record, @intCast(leader), @intCast(target), party_ids[0..self.partyCount()], homes[0..count], self.camera_ticks);
    for (0..self.partyCount()) |actor| if (self.unite_vm.members[actor]) |member| {
        if (member.leader != leader) continue;
        const position = layout.worldPosition(self, actor);
        self.unite_vm.actors[actor].position_q12 = position.toQ12Rounded();
        self.unite_vm.actors[actor].screen_offset = self.actor_transforms[actor].screen_offset;
        self.unite_vm.actors[actor].baseline_offset = self.partyProfile(actor).effect_offset orelse .{ 0, 0 };
        self.unite_vm.actors[actor].signals = self.unite_flags[actor];
    };
}
pub fn prepareUniteImpactEffect(self: *State, leader: usize) !void {
    const effect = if (self.active) |*value| value else return error.InvalidUniteSceneBinding;
    if (effect.kind != .unite or effect.actor != leader or effect.unite_impact_effect != null) return error.InvalidUniteSceneBinding;
    const boundary = self.uniteBoundaryFor(leader) orelse return error.InvalidUniteSceneBinding;
    const id = self.unite_actors.?.find(boundary.record_index).?.impact_effect orelse return error.InvalidUniteSceneBinding;
    const position = layout.worldPosition(self, effect.target);
    effect.unite_impact_effect = .{ .clip = id, .origin_q12 = position.toQ12Rounded() };
}
fn checkChildClip(self: *const State, resource: actor_host.Resource, animation: u16, secondary: bool, record: u8) !void {
    const clip = resource.find(animation).?;
    if (!secondary and std.mem.eql(u8, resource.id, "shared_impacts")) {
        const packet = self.spell_scenes orelse return error.MissingUniteActorArt;
        for (packet.unite_impacts) |impact| if (impact.id == animation and impact.frames.len == clip.frames.len) return;
        return error.MissingUniteActorArt;
    }
    for (clip.frames) |frame| if (self.content.uniteGraphicPose(resource.id, frame.pose, record) == null) return error.MissingUniteActorArt;
}
pub fn advanceUniteActors(self: *State) void {
    if (self.trick_wave) |wave| if (wave.wave.finished and wave.updated_at != self.camera_ticks) {
        self.trick_wave = null;
    };
    defer self.issueUniteReactionCamera();
    defer self.advanceUniteReactionEvents();
    if (self.unite_actors == null or self.replay_exhausted or self.replay_unsupported != null) return;
    self.advancePhysicalRunes();
    if (self.replay_exhausted or self.replay_unsupported != null) return;
    self.advanceUniteScene();
    if (self.replay_exhausted or self.replay_unsupported != null) return;
    if (self.unite_scene) |*scene| if (scene.pending_sound) |sound| {
        self.unite_vm.emitSound(self.camera_ticks, scene.owner, sound) catch {
            self.replay_unsupported = .coordinator_action;
            return;
        };
        scene.pending_sound = null;
    };
    var present = false;
    for (0..self.partyCount()) |actor| if (self.unite_vm.members[actor]) |member| {
        if (self.unite_boundaries[member.leader] == null) {
            self.unite_vm.members[actor] = null;
        } else {
            // shortcut: rotated Master–Pupil and Kai Flash bodies need the rotated packet footprint.
            if ((member.record == 31 or (member.record == 10 and std.mem.eql(u8, self.progress.party[actor].id, "kai"))) and !std.mem.eql(i16, &self.actor_transforms[actor].node_angles, &.{ 0, 0, 0 })) {
                self.replay_unsupported = .coordinator_action;
                return;
            }
            present = true;
        }
    };
    if (!present and !self.unite_vm.hasAuxiliary() and !self.unite_vm.hasPhysical() and !self.unite_vm.hasCounter() and !self.unite_vm.hasEnemyMagic() and !self.unite_vm.hasCommander() and !self.unite_vm.hasEnemyWave()) return;
    for (0..self.partyCount() + self.enemyCount()) |actor| {
        if (self.unite_vm.ownsActor(actor) or self.unite_vm.idle[actor] != null) continue;
        const position = layout.worldPosition(self, actor);
        const home = self.uniteVmHome(actor);
        const attachment: ?[2]i16 = if (self.uniteReactionPose(actor)) |pose| .{ pose.impact_offset.?[0], pose.impact_offset.?[1] } else null;
        self.unite_vm.actors[actor] = actor_host.Actor.anchor(position.toQ12Rounded(), home.toQ12Rounded(), attachment);
        self.unite_vm.actors[actor].signals = self.unite_flags[actor];
        const profile = if (actor < self.partyCount()) self.partyProfile(actor) else self.enemy(actor - self.partyCount());
        self.unite_vm.actors[actor].baseline_offset = profile.effect_offset orelse .{ 0, 0 };
    }
    self.unite_vm.update(self, layout.cameraForTransition(self)) catch |err| {
        if (err == error.RandomInputExhausted) self.replay_exhausted = true else if (!self.replay_exhausted) self.replay_unsupported = .coordinator_action;
        return;
    };
    self.finishPhysicalRuneActors();
    self.finishCounterActors();
    self.finishEnemyMagicActors();
    self.finishCommanderActors();
    self.finishEnemyWaveActors();
    for (0..self.partyCount()) |actor| if (self.unite_vm.members[actor]) |member| {
        if (!self.unite_vm.actors[actor].released or !self.unite_vm.actors[actor].machine.?.halted) continue;
        if (self.martial_queue) |queue| if (queue.owner == member.leader) continue;
        self.finishUniteMember(member.leader, actor);
        if (self.replay_exhausted or self.replay_unsupported != null) return;
        if (self.content.world_art == null) self.actor_transforms[actor].screen_offset = self.unite_vm.actors[actor].screen_offset;
        self.unite_returns[actor] = null;
        self.unite_vm.members[actor] = null;
    };
}
pub fn prepareUniteScene(self: *State, leader: usize) !void {
    const boundary = self.uniteBoundaryFor(leader) orelse return error.InvalidUniteSceneBinding;
    const binding = self.unite_actors.?.find(boundary.record_index).?;
    if (binding.wave_heights) |heights| {
        try self.beginTrickWave(leader, heights);
        return;
    }
    if (binding.target_queue) |timing| {
        try self.beginMartialQueue(leader, timing);
        return;
    }
    const spec = binding.controller orelse return;
    if (self.unite_scene != null) return error.InvalidUniteSceneBinding;
    const trigger = if (spec.mode == .owner_clock) leader else boundary.participantsSlice()[spec.trigger_member];
    const packet = self.spell_scenes orelse return error.MissingUniteScene;
    var local = systems.Draws{ .prng = self.random };
    var instance = try spell_scene.Instance.beginUnite(packet, packet.uniteIndexOf(spec.vfx) orelse return error.MissingUniteScene, layout.currentCamera(self.*), self.replay_draws orelse &local);
    if (spec.mode == .orbit) {
        const target = self.uniteReactionOriginQ12(self.active.?.target);
        for (0..3) |axis| instance.target[axis] = target[axis] >> 12;
    }
    if (self.replay_draws == null) self.random = local.prng.?;
    self.active.?.scene = instance;
    self.unite_scene = .{ .owner = @intCast(leader), .record = boundary.record_index, .trigger = @intCast(trigger), .updated_at = self.camera_ticks };
}
pub fn advanceUniteScene(self: *State) void {
    self.stepUniteScene() catch |err| {
        if (err == error.RandomInputExhausted) self.replay_exhausted = true else self.replay_unsupported = .coordinator_action;
    };
}
pub fn stepUniteScene(self: *State) !void {
    if (self.replay_exhausted or self.replay_unsupported != null) return;
    const scene = if (self.unite_scene) |*value| value else return;
    if (scene.updated_at == self.camera_ticks) return;
    const binding = self.unite_actors.?.find(scene.record).?;
    const spec = binding.controller.?;
    scene.updated_at = self.camera_ticks;
    if (scene.started_at == null) {
        if (self.unite_flags[scene.trigger] & spec.signal == 0) return;
        scene.started_at = self.camera_ticks;
        if (spec.mode == .beauty) {
            const request = self.active.?.scene.?.sceneProgram(self.spell_scenes.?).cameras[0];
            if (self.actor_camera == null) self.actor_camera = try @import("battle_camera").ActorController.init(layout.cameraForTransition(self));
            try self.actor_camera.?.requestBlock(request.target, request.updates);
        }
    }
    if (spec.mode == .owner_clock and self.unite_flags[scene.trigger] & spec.signal == 0) return;
    const elapsed: u16 = if (spec.mode == .owner_clock) self.active.?.scene.?.elapsed + 1 else @intCast(self.camera_ticks - scene.started_at.? + 1);
    if (elapsed >= spec.cleanup_at) {
        self.unite_scene = null;
        return;
    }
    if (spec.orbit) |orbit| {
        if (elapsed == 1) {
            const boundary = self.uniteBoundaryFor(scene.owner) orelse return error.InvalidUniteSceneBinding;
            scene.orbit_origin_q12 = self.unite_vm.actors[boundary.participantsSlice()[orbit.anchor_member]].position_q12;
            scene.orbit_origin_q12[2] +%= orbit.base_z_q12;
        }
        const age = elapsed -| (orbit.hold_updates + 1);
        if (elapsed > orbit.hold_updates and age < orbit.heights_q12.len) {
            if (age == 0) {
                const target = self.uniteReactionOriginQ12(self.active.?.target);
                scene.orbit_velocity_x_q12 = @divTrunc(target[0] -% scene.orbit_origin_q12[0], orbit.divisor);
            }
            scene.orbit_origin_q12[0] +%= scene.orbit_velocity_x_q12;
            scene.orbit_origin_q12[2] = orbit.base_z_q12 +% orbit.heights_q12[age];
        }
        for (0..3) |axis| self.active.?.scene.?.caster[axis] = scene.orbit_origin_q12[axis] >> 12;
        for (orbit.sounds) |sound| if (sound.at == elapsed) {
            if (scene.pending_sound != null) return error.ActorSoundOverflow;
            scene.pending_sound = sound.id;
        };
    }
    if (elapsed == spec.recipient_at) {
        if (spec.mode == .orbit) {
            const target = self.active.?.target;
            if (self.hp(target) > 0) self.startUniteReaction(target, scene.record, spec.recipient_variant, self.uniteReactionOriginQ12(target));
        } else for (self.partyCount()..self.partyCount() + self.enemyCount()) |target| if (self.hp(target) > 0) self.startUniteReaction(target, scene.record, spec.recipient_variant, self.uniteReactionOriginQ12(target));
    }
    const phase_age = elapsed -| spec.recipient_at;
    if (elapsed >= spec.recipient_at and phase_age < spec.recipient_rolls.len) {
        for (self.partyCount()..self.partyCount() + self.enemyCount()) |target| {
            if (self.hp(target) == 0) continue;
            self.actor_transforms[target].node_angles[0] = if (phase_age + 1 < spec.recipient_rolls.len) 1 else 0;
            self.actor_transforms[target].node_angles[2] = if (phase_age + 1 < spec.recipient_rolls.len) spec.recipient_rolls[phase_age] else 0;
        }
    }
    if (spec.mode != .owner_clock and elapsed == spec.damage_at) {
        for (self.unite_vm.members, 0..) |maybe, member| if (maybe) |value| {
            if (value.leader != scene.owner) continue;
            self.unite_flags[member] |= unite_systems.rules.ready_flag;
            self.unite_vm.actors[member].signals |= unite_systems.rules.ready_flag;
        };
    }
    var local = systems.Draws{ .prng = self.random };
    try self.active.?.scene.?.advance(self.spell_scenes.?, elapsed, self.replay_draws orelse &local);
    if (self.replay_draws == null) self.random = local.prng.?;
    if (spec.mode == .owner_clock and elapsed == spec.return_at.?) {
        self.unite_flags[scene.trigger] &= ~spec.signal;
        self.unite_vm.actors[scene.trigger].signals &= ~spec.signal;
        self.unite_scene = null;
    }
}
pub fn applyUniteReactionSignals(self: *State, index: usize, age: u32) void {
    const reaction = self.uniteReactionProgram(index) orelse return;
    for (reaction.signals, 0..) |event, ordinal| {
        const bit = @as(u8, 1) << @as(u3, @intCast(ordinal));
        if (age != event.at or self.unite_reactions[index].?.signals_applied & bit != 0) continue;
        if (event.set) self.unite_flags[index] |= event.bits else self.unite_flags[index] &= ~event.bits;
        self.unite_vm.actors[index].signals = self.unite_flags[index];
        self.unite_reactions[index].?.signals_applied |= bit;
    }
}
pub fn advanceUniteReactionEvents(self: *State) void {
    if (self.replay_exhausted or self.replay_unsupported != null) return;
    for (0..self.partyCount() + self.enemyCount()) |index| {
        const instance = self.unite_reactions[index] orelse continue;
        // The completed knockout sample keeps the recipient hidden during other action tails.
        if (instance.knockout_ticks != 0) continue;
        if (self.hp(index) == 0) {
            self.unite_reactions[index] = null;
            continue;
        }
        const reaction = self.uniteReactionProgram(index) orelse continue;
        const age = self.camera_ticks - instance.started_at;
        self.applyUniteReactionSignals(index, age);
        while (self.unite_reactions[index].?.sound_cursor < reaction.sounds.len) {
            const event = reaction.sounds[self.unite_reactions[index].?.sound_cursor];
            if (event.at > age) break;
            if (event.at == age) {
                self.unite_vm.emitSound(self.camera_ticks, @intCast(index), event.id) catch {
                    self.replay_unsupported = .coordinator_action;
                    return;
                };
            }
            self.unite_reactions[index].?.sound_cursor += 1;
        }
        for (reaction.status_attempts, 0..) |event, ordinal| {
            const bit = @as(u8, 1) << @as(u3, @intCast(ordinal));
            if (age != event.at or instance.status_applied & bit != 0) continue;
            switch (event.kind) {
                .enemy_sleep => status.requestUniteEnemySleep(self, index, event.failure_percent) catch |err| {
                    if (err != error.RandomInputExhausted) self.replay_unsupported = .coordinator_action;
                    return;
                },
            }
            self.unite_reactions[index].?.status_applied |= bit;
        }
    }
}
pub fn issueUniteReactionCamera(self: *State) void {
    if (self.replay_exhausted or self.replay_unsupported != null) return;
    for (0..self.partyCount() + self.enemyCount()) |index| {
        if (self.unite_reactions[index] == null) continue;
        const reaction = self.uniteReactionProgram(index) orelse continue;
        if (reaction.focus_z_pulses.len == 0 or self.hp(index) == 0) continue;
        const age = self.camera_ticks - self.unite_reactions[index].?.started_at;
        for (reaction.focus_z_pulses) |pulse| {
            if (age != pulse.at) continue;
            if (self.actor_camera == null) self.actor_camera = @import("battle_camera").ActorController.init(layout.cameraForTransition(self)) catch {
                self.replay_unsupported = .coordinator_action;
                return;
            };
            // The source changes only Z velocity and the timer; X/Y and the target survive.
            self.actor_camera.?.velocity[0][2] = pulse.delta_q12;
            self.actor_camera.?.remaining[0] = 1;
        }
    }
}
