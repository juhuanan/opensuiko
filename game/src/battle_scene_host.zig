const actor_host = @import("battle_actor_host.zig");
const std = @import("std");
const battle_systems = @import("battle_systems");
const unite_systems = battle_systems.unite;
const layout = @import("battle_layout.zig");
const drops = @import("battle_drops.zig");
const camera = @import("battle_camera");
const spell_scene = @import("battle_spell_scene.zig");
const systems = @import("battle_rules");
const battle = @import("battle.zig");
const types_mod = @import("battle_types.zig");
const State = battle.State;
const Position = types_mod.Position;

pub fn attachUniteActors(self: *State, bundle: *const actor_host.Bundle) !void {
    try bundle.validate();
    for (self.content.enemies) |enemy| if (enemy.action_policy == .source_melee or enemy.action_policy == .source_magic or enemy.action_policy == .source_projectile) {
        const reactions = bundle.counterPacket() orelse return error.MissingCounterProgram;
        if (reactions.meleeEnemy(enemy.id) == null) return error.MissingCounterProgram;
        if (reactions.meleeEnemy(enemy.id).?.vine_art) |art| {
            for ([_]u16{ art.strip, art.leaves[0], art.leaves[1] }) |pose| {
                if (self.content.uniteGraphicPose(enemy.id, pose, null) == null) return error.InvalidUniteGraphics;
            }
            const strip = self.content.uniteGraphicPose(enemy.id, art.strip, null).?.sprite;
            if (strip.rect.w != 16 or strip.rect.h != 8) return error.InvalidUniteGraphics;
            for (art.leaves, art.leaf_extents) |pose, extent| {
                const sprite = self.content.uniteGraphicPose(enemy.id, pose, null).?.sprite;
                if (extent[0] > sprite.rect.w or extent[1] > sprite.rect.h) return error.InvalidUniteGraphics;
            }
        }
        if (enemy.action_policy == .source_magic and (bundle.enemy_magic == null or !std.mem.eql(u8, bundle.enemy_magic.?.id, enemy.id))) return error.MissingEnemyMagicBinding;
    };
    for (self.content.enemies) |enemy| if (enemy.action_policy == .source_commander) {
        const binding = bundle.commander orelse return error.MissingEnemyOrderBinding;
        if (!std.mem.eql(u8, binding.id, enemy.id)) return error.MissingEnemyOrderBinding;
        const art = @import("battle_physical_host.zig");
        const resource = bundle.animations.find(enemy.id) orelse return error.MissingActorResource;
        if (self.content.presentation_ready) {
            try art.checkProgramArt(self.*, bundle, resource, binding.order_program, 0, 0, false);
            try art.checkProgramArt(self.*, bundle, resource, binding.solo_program.?, 0, 0, false);
        }
    };
    for (self.content.enemies) |enemy| if (enemy.action_policy == .source_rabbit) {
        const packet = bundle.counterPacket() orelse return error.MissingRabbitBinding;
        const projectile = (packet.meleeEnemy(enemy.id) orelse return error.MissingRabbitBinding).projectile orelse return error.MissingRabbitBinding;
        if (projectile.camera == null) return error.MissingRabbitBinding;
        const resource = packet.animations.find(enemy.id) orelse return error.MissingActorResource;
        if (self.content.presentation_ready) {
            const art = @import("battle_physical_host.zig");
            try art.checkProgramArt(self.*, packet, resource, projectile.owner_program, 0, 0, false);
            try art.checkProgramArt(self.*, packet, resource, projectile.child_program, projectile.animation, 0, true);
        }
    };
    for (self.content.enemies) |enemy| if (enemy.action_policy == .source_ninja) {
        const packet = bundle.counterPacket() orelse return error.MissingNinjaBinding;
        const melee = packet.meleeEnemy(enemy.id) orelse return error.MissingNinjaBinding;
        const special = melee.special orelse return error.MissingNinjaBinding;
        if (special.return_program == null or special.damage_numerator != 3 or special.damage_denominator != 2) return error.MissingNinjaBinding;
        const capability = packet.enemy(enemy.id) orelse return error.MissingNinjaBinding;
        const defender = packet.defenderFor(enemy.id, .parry) orelse return error.MissingNinjaBinding;
        if (capability.counterable) return error.MissingNinjaBinding;
        const resource = packet.animations.find(enemy.id) orelse return error.MissingActorResource;
        if (self.content.presentation_ready) {
            const art = @import("battle_physical_host.zig");
            for ([_][]const u8{ melee.attack_program, melee.return_program, special.attack_program, special.return_program.?, defender.response_program, defender.strike_program }) |program| try art.checkProgramArt(self.*, packet, resource, program, 0, 0, false);
        }
    };
    for (self.content.enemies) |enemy| if (enemy.action_policy == .source_dagon) {
        const packet = bundle.counterPacket() orelse return error.MissingDagonBinding;
        const melee = packet.meleeEnemy(enemy.id) orelse return error.MissingDagonBinding;
        const special = melee.special orelse return error.MissingDagonBinding;
        if (special.return_camera == null or special.return_program == null or special.damage_numerator != 1 or special.damage_denominator != 2) return error.MissingDagonBinding;
        const capability = packet.enemy(enemy.id) orelse return error.MissingDagonBinding;
        if (!capability.counterable or packet.defenderFor(enemy.id, .parry) != null) return error.MissingDagonBinding;
        if (self.content.presentation_ready) {
            const art = @import("battle_physical_host.zig");
            const resource = packet.animations.find(enemy.id) orelse return error.MissingActorResource;
            for ([_][]const u8{ melee.attack_program, melee.return_program, special.attack_program }) |program| try art.checkProgramArt(self.*, packet, resource, program, 0, 0, false);
        }
    };
    for (self.content.enemies) |enemy| if (enemy.action_policy == .source_whip_wolf) {
        const binding = bundle.commanderFor(enemy.id) orelse return error.MissingEnemyOrderBinding;
        const packet = bundle.counterPacket() orelse return error.MissingEnemyOrderBinding;
        const melee = packet.meleeEnemy(enemy.id) orelse return error.MissingEnemyOrderBinding;
        if (binding.solo_program != null or binding.recipient_program != null) return error.MissingEnemyOrderBinding;
        if (self.content.presentation_ready) {
            const art = @import("battle_physical_host.zig");
            const resource = bundle.animations.find(enemy.id) orelse return error.MissingActorResource;
            for ([_][]const u8{ binding.order_program, melee.attack_program, melee.return_program }) |program| try art.checkProgramArt(self.*, bundle, resource, program, 0, 0, false);
        }
    };
    for (self.content.enemies) |enemy| if (enemy.action_policy == .source_holly_fairy) {
        const binding = bundle.enemy_wave orelse return error.MissingEnemyWaveBinding;
        const packet = bundle.counterPacket() orelse return error.MissingEnemyWaveBinding;
        const melee = packet.meleeEnemy(enemy.id) orelse return error.MissingEnemyWaveBinding;
        const capability = packet.enemy(enemy.id) orelse return error.MissingEnemyWaveBinding;
        const parry = packet.defenderFor(enemy.id, .parry) orelse return error.MissingEnemyWaveBinding;
        if (!std.mem.eql(u8, binding.id, enemy.id) or !capability.counterable) return error.MissingEnemyWaveBinding;
        const idle = @import("battle_enemy_idle.zig").program_id;
        if (bundle.programs.find(idle) == null) return error.MissingEnemyIdleBinding;
        const resource = bundle.animations.find(enemy.id) orelse return error.MissingActorResource;
        try packet.validateProgram(idle, resource);
        if (self.content.presentation_ready) {
            const art = @import("battle_physical_host.zig");
            for ([_][]const u8{ idle, binding.owner_program, melee.attack_program, melee.return_program, parry.response_program, parry.strike_program }) |program| try art.checkProgramArt(self.*, bundle, resource, program, 0, 0, false);
        }
    };
    for (self.content.enemies) |enemy| if (enemy.action_policy == .source_sorcerer or enemy.action_policy == .source_siren or enemy.action_policy == .source_earth_golem) {
        const binding = bundle.areaMagicFor(enemy.id) orelse return error.MissingEnemyMagicBinding;
        const packet = bundle.counterPacket() orelse return error.MissingCounterProgram;
        const melee = packet.meleeEnemy(enemy.id) orelse return error.MissingCounterProgram;
        const capability = packet.enemy(enemy.id) orelse return error.MissingCounterProgram;
        const dodge = packet.rangedDodge(enemy.id) orelse return error.MissingCounterProgram;
        if (capability.counterable or packet.defenderFor(enemy.id, .parry) != null) return error.MissingCounterProgram;
        if (self.content.presentation_ready) {
            const art = @import("battle_physical_host.zig");
            const resource = bundle.animations.find(enemy.id) orelse return error.MissingActorResource;
            for ([_][]const u8{ melee.attack_program, melee.return_program, binding.owner_program }) |program| try art.checkProgramArt(self.*, bundle, resource, program, 0, 0, false);
            if (self.spell_scenes != null) try art.checkProgramArt(self.*, bundle, resource, dodge.response_program, 0, 0, false);
            if (binding.worker.waves) |waves| for (waves.note_poses) |pose| {
                if (self.content.uniteGraphicPose(enemy.id, pose, null) == null) return error.InvalidUniteGraphics;
            };
        }
    };
    for (self.content.enemies) |enemy| if (enemy.action_policy == .source_creeper or enemy.action_policy == .source_shadow_man or enemy.action_policy == .source_mirage_f or enemy.action_policy == .source_mirage_h) {
        const regional = bundle.regionalFor(enemy.id) orelse return error.MissingCounterProgram;
        const packet = bundle.counterPacket() orelse return error.MissingCounterProgram;
        const melee = packet.meleeEnemy(enemy.id) orelse return error.MissingCounterProgram;
        const capability = packet.enemy(enemy.id) orelse return error.MissingCounterProgram;
        const dodge = packet.rangedDodge(enemy.id) orelse return error.MissingCounterProgram;
        if (enemy.action_policy == .source_creeper and (!capability.counterable or melee.special == null or regional.special_recipient_return == null)) return error.MissingCounterProgram;
        if (enemy.action_policy != .source_creeper and capability.counterable) return error.MissingCounterProgram;
        if ((enemy.action_policy == .source_mirage_f or enemy.action_policy == .source_mirage_h) and melee.special == null) return error.MissingCounterProgram;
        if (regional.mirage_visual) |visual| {
            const sprite = (self.content.uniteGraphicPose(enemy.id, visual.pose, null) orelse return error.InvalidUniteGraphics).sprite;
            if (@as(i32, visual.crop[0]) + visual.crop[2] > sprite.rect.w or @as(i32, visual.crop[1]) + visual.crop[3] > sprite.rect.h or
                @as(i32, sprite.anchor_x) - visual.crop[0] < std.math.minInt(i16) or
                @as(i32, sprite.anchor_y) - visual.crop[1] < std.math.minInt(i16)) return error.InvalidUniteGraphics;
        }
        if (self.content.presentation_ready) {
            const art = @import("battle_physical_host.zig");
            const resource = bundle.animations.find(enemy.id) orelse return error.MissingActorResource;
            try art.checkProgramArt(self.*, bundle, resource, melee.attack_program, 0, 0, false);
            if (!regional.direct_attack) try art.checkProgramArt(self.*, bundle, resource, melee.return_program, 0, 0, false);
            if (melee.special) |special| try art.checkProgramArt(self.*, bundle, resource, special.attack_program, 0, 0, false);
            if (self.spell_scenes != null) try art.checkProgramArt(self.*, bundle, resource, dodge.response_program, 0, 0, false);
            for (0..self.partyCount()) |slot| {
                const party_id = self.progress.party[slot].id;
                const party_res = bundle.animations.find(party_id) orelse return error.MissingActorResource;
                if (regional.direct_attack) {
                    const reaction = packet.partyReaction(party_id) orelse return error.MissingCounterProgram;
                    const ret_prog = reaction.return_program orelse return error.MissingCounterProgram;
                    if (self.spell_scenes != null) try art.checkProgramArt(self.*, bundle, party_res, melee.hurt_program, 0, 0, false);
                    try art.checkProgramArt(self.*, bundle, party_res, ret_prog, 0, 0, false);
                }
                if (self.spell_scenes != null) {
                    if (regional.special_recipient_return) |ret| try art.checkProgramArt(self.*, bundle, party_res, ret, 0, 0, false);
                }
            }
        }
    };
    for (self.content.unite_graphics) |graphic| {
        const resource = bundle.animations.find(graphic.id) orelse return error.InvalidUniteGraphics;
        for (graphic.poses) |pose| if (pose.id >= resource.pose_count) return error.InvalidUniteGraphics;
    }
    if (self.integrationHost()) |host| for (bundle.unites) |unite| {
        const record = host.uniteCatalogue().recordAt(unite.record) orelse return error.InvalidUniteSceneBinding;
        if (unite.members.len != record.member_count) return error.InvalidUniteSceneBinding;
        for (unite.members) |member| if (member.reaction_group and !record.all_enemies) return error.InvalidUniteSceneBinding;
        for (unite.members, record.membersSlice()) |member, native_id| {
            if (host.characterId(member.id) != native_id) return error.InvalidUniteSceneBinding;
        }
    };
    self.unite_actors = bundle;
}
pub fn attachSpellScenes(self: *State, packet: *const spell_scene.Packet) !void {
    try packet.validate(4096, 4096);
    if (self.content.systems) |systems_data| for (packet.spells) |scene| if (scene.program) |program| {
        for (systems_data.spells) |spell| if (std.mem.eql(u8, spell.id, scene.id) and spell.group != program.group) return error.InvalidSpellSceneBinding;
    };
    self.spell_scenes = packet;
}
pub fn hasSpellScene(self: *const State) bool {
    return if (self.active) |*effect| effect.kind == .cast and effect.scene != null else false;
}
pub fn hasSourceEffect(self: State) bool {
    if (self.unite_vm.hasCommander()) return true;
    if (self.unite_vm.hasEnemyWave()) return true;
    if (self.unite_vm.hasEnemyMagic()) return true;
    if (self.unite_vm.hasPhysical()) return true;
    if (self.unite_vm.hasCounter()) return true;
    if (self.active) |effect| if (effect.unite_impact_effect) |visual| if (visual.started_at != null) return true;
    return self.unite_scene != null or self.hasSpellScene() or self.hasDrops() or self.hasUniteScene() or self.hasUniteReactionEffects() or hasPhysicalImpacts(&self);
}
pub fn hasStatusIcons(self: State) bool {
    for (0..self.partyCount()) |actor| if (self.hasStatusIconsFor(actor)) return true;
    return false;
}
pub fn hasStatusIconsFor(self: State, actor: usize) bool {
    const packet = self.spell_scenes orelse return false;
    if (actor >= self.partyCount() or packet.status_icons.len == 0 or self.hasDrops() or (self.departed[actor] and self.departures[actor] == null) or self.status_icons[actor].active == 0) return false;
    const anchors = packet.statusAnchors(self.progress.party[actor].id) orelse return false;
    const pose = layout.actorLayout(self, actor).source_pose orelse return false;
    return pose < anchors.offsets.len;
}
pub fn hasUniteScene(self: State) bool {
    if (!self.hasLiveUniteActors() and !self.hasUniteTracks()) return false;
    const boundary = self.activeUniteBoundary() orelse return false;
    if (self.hasLiveUniteActors()) if (self.unite_actors.?.find(boundary.record_index)) |binding| {
        if (!binding.damage_reaction) return true;
    };
    return self.hasUniteReactionBinding(boundary.record_index, 0, self.active.?.target);
}
pub fn hasUniteReactionBinding(self: *const State, record: u8, variant: u8, target: usize) bool {
    const pose = self.uniteReactionPose(target) orelse return false;
    const packet = self.spell_scenes orelse return false;
    for (packet.unite_reactions) |reaction| if (reaction.record == record and reaction.variant == variant and reaction.blocker == null) {
        if (reaction.palette_cycle) |cycle| {
            if ((if (cycle.row == 1) pose.flash_entries else pose.shock_entries) == null) return false;
            for (reaction.poses) |event| if (event.at > cycle.start and event.at < cycle.stop and event.animation == 0) {
                if (cycle.row != 1 or pose.idle_flash == null) return false;
            };
        }
        return true;
    };
    return false;
}
pub fn advanceUniteTransition(self: *State) void {
    if (!self.hasLiveUniteActors()) return;
    const effect = self.active.?;
    const binding = self.unite_actors.?.find(self.activeUniteBoundary().?.record_index).?;
    if (binding.beat_child != null) {
        const pose = self.uniteReactionPose(effect.target) orelse {
            self.replay_unsupported = .coordinator_action;
            return;
        };
        const attachment = pose.source_attachment orelse {
            self.replay_unsupported = .coordinator_action;
            return;
        };
        self.unite_vm.advanceCallbackChild(self, @intCast(effect.actor), self.uniteReactionOriginQ12(effect.target), attachment, layout.cameraForTransition(self)) catch {
            self.replay_unsupported = .coordinator_action;
            return;
        };
    }
    self.unite_vm.advanceTransition(self.unite_actors.?, @intCast(self.active.?.actor), &self.unite_flags) catch {
        self.replay_unsupported = .coordinator_action;
    };
}
pub fn uniteAssistAfterDamage(self: State) bool {
    if (!self.hasLiveUniteActors()) return false;
    const boundary = self.activeUniteBoundary() orelse return false;
    return self.unite_actors.?.find(boundary.record_index).?.assist_after_damage;
}
pub fn resolveUniteAssistReactions(self: *State) void {
    if (!self.hasLiveUniteActors() and !self.hasUniteTracks()) return;
    const boundary = self.activeUniteBoundary() orelse return;
    for (boundary.participantsSlice(), 0..) |member, ordinal| {
        const track = self.uniteTrack(member);
        const live = self.unite_vm.members[member];
        const reacts = if (live) |value| value.initialized and value.reaction_on_hit else if (track) |value| value.reaction_on_hit else false;
        if (!reacts or self.unite_flags[member] & unite_systems.rules.hit_flag == 0) continue;
        if (live == null and self.effectTicks() != track.?.start_after + track.?.motion.impact_tick + 1) continue;
        if (live != null) if (self.unite_actors.?.find(boundary.record_index).?.members[ordinal].hit_camera) |request| {
            if (self.actor_camera == null) self.actor_camera = @import("battle_camera").ActorController.init(layout.cameraForTransition(self)) catch {
                self.replay_unsupported = .coordinator_action;
                return;
            };
            self.actor_camera.?.requestBlock(request.target, request.updates) catch {
                self.replay_unsupported = .coordinator_action;
                return;
            };
        };
        const group = if (live) |value| value.reaction_group else false;
        const first = if (group) self.partyCount() else self.active.?.target;
        const end = if (group) self.partyCount() + self.enemyCount() else first + 1;
        for (first..end) |target| if (self.hp(target) > 0) self.startUniteReaction(target, boundary.record_index, if (live) |value| value.reaction_variant else 0, self.uniteReactionOriginQ12(target));
        self.unite_flags[member] &= ~unite_systems.rules.hit_flag;
        if (live != null) self.unite_vm.actors[member].signals &= ~unite_systems.rules.hit_flag;
    }
}
pub fn uniteReactionProgram(self: *const State, index: usize) ?spell_scene.UniteReaction {
    const instance = self.unite_reactions[index] orelse return null;
    if (instance.knockout_ticks != 0) return null;
    const packet = self.spell_scenes orelse return null;
    for (packet.unite_reactions) |reaction| if (reaction.record == instance.record and reaction.variant == instance.variant and reaction.blocker == null) return reaction;
    return null;
}
pub fn uniteRecipientLocked(self: State, index: usize) bool {
    const instance = self.unite_reactions[index] orelse return false;
    if (instance.knockout_ticks != 0) return self.camera_ticks -% instance.started_at < instance.knockout_ticks;
    if (self.hp(index) == 0) return false;
    const reaction = self.uniteReactionProgram(index) orelse return false;
    return reaction.locks_target and (reaction.retain_lock or self.camera_ticks - instance.started_at < reaction.duration);
}
pub fn uniteReactionPose(self: State, index: usize) ?spell_scene.HurtPose {
    const packet = self.spell_scenes orelse return null;
    const id = if (index < self.partyCount()) self.progress.party[index].id else self.enemy(index - self.partyCount()).id;
    return packet.reactionPose(id);
}
pub fn uniteActorPosition(self: *const State, index: usize) ?Position {
    if (self.unite_reactions[index]) |instance| if (instance.knockout_ticks != 0) {
        if (!self.uniteRecipientLocked(index)) return null;
        const position = instance.origin_q12;
        return .{ .x = @floatFromInt(position[0] >> 12), .y = @floatFromInt(position[1] >> 12), .z = @floatFromInt(position[2] >> 12) };
    };
    const fallback: ?Position = if (self.unite_vm.position(index)) |position_q12| .{ .x = @floatFromInt(position_q12[0] >> 12), .y = @floatFromInt(position_q12[1] >> 12), .z = @floatFromInt(position_q12[2] >> 12) } else null;
    if (fallback != null and self.unite_vm.ownsActor(index)) return fallback;
    const reaction = self.uniteReactionProgram(index) orelse return fallback;
    const instance = self.unite_reactions[index].?;
    const age = self.camera_ticks - instance.started_at;
    if (self.unite_vm.idle[index] != null and age >= reaction.duration) return fallback;
    const absolute_tail = reaction.motions.len != 0 and reaction.motions[reaction.motions.len - 1].absolute;
    if (self.hp(index) == 0 or (age >= reaction.duration and !absolute_tail and !reaction.retain_lock)) return fallback;
    const position = spell_scene.unitePosition(reaction, instance.origin_q12, instance.home_q12, age);
    return .{ .x = @floatFromInt(position[0] >> 12), .y = @floatFromInt(position[1] >> 12), .z = @floatFromInt(position[2] >> 12) };
}
pub fn hasUniteReactionEffects(self: State) bool {
    for (0..self.partyCount() + self.enemyCount()) |index| {
        const reaction = self.uniteReactionProgram(index) orelse continue;
        if (self.hp(index) == 0) continue;
        const age = self.camera_ticks - self.unite_reactions[index].?.started_at;
        for (reaction.impacts) |spawn| for (self.spell_scenes.?.unite_impacts) |clip| if (clip.id == spawn.animation) {
            var duration: u32 = 0;
            for (clip.frames) |frame| duration += frame.ticks;
            if (age >= spawn.at and age - spawn.at + 1 < duration) return true;
        };
    }
    return false;
}
pub fn spellReaction(self: State, index: usize) ?spell_scene.ReactionSample {
    var sample = baseSpellReaction(self, index);
    if (self.unite_vm.ownsActor(index)) {
        const actor = &self.unite_vm.actors[index];
        if (actor.color != null or !actor.visible) {
            if (sample == null) sample = .{ .offset = .{ 0, 0 } };
            if (actor.color) |color| sample.?.color = color;
            sample.?.visible = sample.?.visible and actor.visible;
        }
    }
    return sample;
}
fn baseSpellReaction(self: State, index: usize) ?spell_scene.ReactionSample {
    if (self.unite_reactions[index]) |instance| if (instance.knockout_ticks != 0) {
        const elapsed = self.camera_ticks -% instance.started_at;
        if (elapsed >= instance.knockout_ticks) return .{ .visible = false, .offset = .{ 0, 0 } };
        const pose = self.uniteReactionPose(index) orelse return null;
        return spell_scene.knockoutAfterHurt(pose, @intCast(elapsed));
    };
    if (self.physicalRuneReaction(index)) |reaction| return reaction;
    if (self.uniteReactionProgram(index)) |reaction| {
        if (self.hp(index) > 0) if (self.uniteReactionPose(index)) |pose| {
            if (spell_scene.uniteReactionAt(reaction, pose, self.camera_ticks - self.unite_reactions[index].?.started_at)) |sample| return sample;
        };
    }
    if (physicalWhite(&self, index)) |sample| return sample;
    const effect = self.active orelse return null;
    if (effect.kind != .cast or effect.scene == null) return null;
    const instance = &effect.scene.?;
    if (effect.instant_knockouts & (@as(u16, 1) << @intCast(index)) != 0) return .{ .visible = false, .offset = .{ 0, 0 } };
    if (self.content.systems.?.spells[effect.spell].kind == .sleep and index >= self.partyCount() and (self.enemy(index - self.partyCount()).death_immune orelse false)) return null;
    if (index < self.partyCount() and self.spell_scenes.?.spells[instance.spell].program.?.party_reaction != null) {
        if (!self.participates(index)) return null;
        return spell_scene.partyReactionAt(self.spell_scenes.?, instance, self.effectTicks(), self.progress.party[index].id);
    }
    if (self.spell_scenes.?.spells[instance.spell].program.?.actor_motion != null) {
        var eligible = false;
        for (instance.targets[0..instance.target_count]) |target| if (target.actor == index and target.movable) {
            eligible = true;
            break;
        };
        if (!eligible) return null;
    }
    const group = self.spell_scenes.?.spells[instance.spell].program.?.group;
    if (group) {
        var found = false;
        for (instance.targets[0..instance.target_count]) |target| if (target.actor == index) {
            found = true;
            break;
        };
        if (!found) return null;
    } else if (effect.target != index) return null;
    const id = if (index < self.partyCount()) self.progress.party[index].id else self.enemy(index - self.partyCount()).id;
    if (index >= self.partyCount() and self.hp(index) == 0 and effect.affected & (@as(u16, 1) << @intCast(index)) != 0) {
        const start = spell_scene.knockoutStart(self.spell_scenes.?.spells[instance.spell].program.?);
        if (self.effectTicks() >= start) for (self.spell_scenes.?.hurt_poses) |pose| if (std.mem.eql(u8, id, pose.id)) return spell_scene.knockoutAt(pose, self.spell_scenes.?.spells[instance.spell].program.?, self.effectTicks() - start);
    }
    return spell_scene.reactionAt(self.spell_scenes.?, instance, self.effectTicks(), id);
}
pub fn effectEntry(self: State, index: u16) drops.Entry {
    return if (self.hasSpellScene() or !self.hasDrops()) self.spell_scenes.?.entries[index] else self.drops_art.?.entries[index];
}
pub fn spellActorPosition(self: *const State, index: usize) ?Position {
    if (!self.hasSpellScene()) return null;
    const instance = &self.active.?.scene.?;
    const program = self.spell_scenes.?.spells[instance.spell].program.?;
    const motion = program.actor_motion orelse return null;
    const age = self.effectTicks();
    if (age >= motion.start + motion.updates and age < motion.returning or age >= motion.returning + motion.updates) return null;
    for (instance.targets[0..instance.target_count]) |target| if (target.actor == index) {
        const sample = (spell_scene.actorTransform(program, target, self.effectTicks()) catch return null) orelse return null;
        return .{ .x = @floatFromInt(sample.position[0] >> 12), .y = @floatFromInt(sample.position[1] >> 12), .z = @floatFromInt(sample.position[2] >> 12) };
    };
    return null;
}
pub fn actorSize(self: State, index: usize) f32 {
    return @as(f32, @floatFromInt(self.actor_sizes[index])) / 4096;
}
pub fn hasBackgroundWarp(self: State) bool {
    return self.backgroundCaptureMinimum() != null;
}
pub fn backgroundCaptureMinimum(self: State) ?u16 {
    if (!self.hasSpellScene()) return null;
    const program = self.spell_scenes.?.spells[self.active.?.scene.?.spell].program.?;
    return spell_scene.backgroundCaptureMinimum(program, self.effectTicks());
}
pub fn effectPixels(self: State, entry: u16, out: *[4096][4]u8) bool {
    return self.hasSpellScene() and spell_scene.erosionPixels(self.spell_scenes.?, &self.active.?.scene.?, entry, out);
}
pub fn spellSceneFrame(self: State) spell_scene.Frame {
    var result = if (self.hasSpellScene()) spell_scene.frameWithCamera(self.spell_scenes.?, &self.active.?.scene.?, self.effectTicks(), layout.currentCamera(self)) else spell_scene.Frame{ .wash = .{ 0, 0, 0 }, .wash_blend = .additive };
    if (self.unite_scene != null) if (self.active) |*effect| if (effect.kind == .unite and effect.scene != null) {
        result = spell_scene.frameWithCamera(self.spell_scenes.?, &effect.scene.?, effect.scene.?.elapsed, layout.currentCamera(self));
    };
    if (self.hasDrops()) {
        const old = self.dropsFrame();
        result.wash = old.wash;
        for (old.commands[0..old.count], 0..) |command, i| result.commands[i] = .{ .vertices = command.vertices, .count = command.count, .colors = command.colors, .texture = if (command.texture) |texture| @as(u16, texture) else null, .tint = @splat(command.intensity), .depth = command.depth };
        result.count = old.count;
    }
    self.appendUniteImpacts(&result);
    appendPhysicalImpacts(&self, &result);
    appendEnemyMagic(&self, &result);
    appendShadowColumns(&self, &result);
    appendStatusIcons(&self, &result);
    return result;
}
fn appendShadowColumns(self: *const State, result: *spell_scene.Frame) void {
    for (self.unite_vm.actors[self.partyCount() .. self.partyCount() + self.enemyCount()]) |*actor| {
        const fade = actor.shadow_fade orelse continue;
        if (fade.updates == 0 or (actor.shared_value != 1 and actor.shared_value != 99)) continue;
        const binding = actor.regional orelse continue;
        const column = binding.shadow_column orelse continue;
        const growth = @as(i32, fade.updates) * column.step_q12;
        const radial_scale = column.radial_start_q12 + growth;
        if (radial_scale > 4096) continue;
        appendColumn(result, layout.currentCamera(self.*), fade.origin, column.shape, column.segments, 0, .{ radial_scale, radial_scale, 4096 - growth });
    }
}

fn appendColumn(result: *spell_scene.Frame, block: camera.Block, origin: [3]i32, shape: spell_scene.ColumnShape, segments: u8, angle_y: i32, scale: [3]i32) void {
    const lower_point: [3]i32 = .{ shape.radius, 0, shape.base_height };
    const upper_point: [3]i32 = .{ shape.top_radius, 0, shape.height };
    var lower: [32]camera.Screen = undefined;
    var upper: [32]camera.Screen = undefined;
    const angle_step = -@divTrunc(4096, @as(i32, segments));
    for (0..segments) |segment| {
        const angles: [3]i32 = .{ 0, angle_y, angle_step * @as(i32, @intCast(segment)) };
        lower[segment] = camera.projectScene(block, spell_scene.vectorTransform(lower_point, angles, scale, origin), .{}) orelse return;
        upper[segment] = camera.projectScene(block, spell_scene.vectorTransform(upper_point, angles, scale, origin), .{}) orelse return;
    }
    for (0..segments) |segment| {
        const next = (segment + 1) % segments;
        const a, const b = .{ upper[segment], upper[next] };
        const c, const d = .{ lower[segment], lower[next] };
        result.append(.{
            .vertices = .{ .{ .x = a.x, .y = a.y }, .{ .x = b.x, .y = b.y }, .{ .x = c.x, .y = c.y }, .{ .x = d.x, .y = d.y } },
            .colors = .{ shape.inner, shape.inner, shape.outer, shape.outer },
            .depth = std.math.clamp(@as(i32, @intFromFloat((a.depth + b.depth + c.depth + d.depth) / 16)), 1, 509),
            .blend = .additive,
        });
    }
}

fn appendEnemyMagic(self: *const State, result: *spell_scene.Frame) void {
    if (!self.unite_vm.hasEnemyMagic()) return;
    const packet = self.spell_scenes orelse return;
    const art = packet.enemy_magic_art orelse return;
    const bundle = self.unite_actors orelse return;
    const block = layout.currentCamera(self.*);
    const scene_scale = @divTrunc(block.scale[0] << 10, block.translation[2]);
    for (self.unite_vm.enemy_magic_actions) |maybe| if (maybe) |action| {
        if (action.area != null) {
            const area_binding = bundle.areaMagicFor(self.enemy(action.owner - self.partyCount()).id) orelse continue;
            const area_frame = action.areaGraphics(area_binding, art);
            for (area_frame.sprites[0..area_frame.sprite_count]) |graphic| {
                var world = action.root;
                for (graphic.position_q12, 0..) |local, axis| world[axis] += @as(i16, @truncate(local >> 12));
                var anchor = @import("battle_camera").projectScene(block, world, .{}) orelse continue;
                if (graphic.kind == .impact or graphic.kind == .golem_impact) {
                    const member: usize = if (graphic.kind == .golem_impact) graphic.index else action.recipient;
                    if (member >= self.partyCount()) continue;
                    const id = self.progress.party[member].id;
                    const pose = self.unite_vm.pose(member) orelse layout.actorLayout(self.*, member).source_pose orelse bundle.animations.find(id).?.find(0).?.frames[0].pose;
                    anchor.x += @floatFromInt(art.center(id, pose) orelse continue);
                }
                const size = @divTrunc(scene_scale * graphic.size, 4096);
                const node = @import("battle_camera").Block{ .focus = .{ 0, 0, 0 }, .angles = .{ 0, 0, graphic.node_angle_z }, .translation = .{ 0, 0, 1024 }, .scale = @splat(size) };
                const entry = packet.entries[graphic.entry];
                const corners = [4][3]i32{ .{ entry.dx, entry.dy, 0 }, .{ entry.dx + entry.w - 1, entry.dy, 0 }, .{ entry.dx, entry.dy + entry.h - 1, 0 }, .{ entry.dx + entry.w - 1, entry.dy + entry.h - 1, 0 } };
                var command = spell_scene.Command{ .vertices = undefined, .texture = graphic.entry, .tint = graphic.tint, .depth = std.math.clamp(@as(i32, @intFromFloat(anchor.depth)) >> 2, 5, 379) };
                for (corners, 0..) |corner, index| {
                    const offset = drops.rawProject(node, corner);
                    command.vertices[index] = .{ .x = anchor.x + @as(f32, @floatFromInt(offset[0])), .y = anchor.y + @as(f32, @floatFromInt(offset[1])) };
                }
                result.append(command);
            }
            const root_vec: [3]i32 = .{ action.root[0], action.root[1], action.root[2] };
            for (area_frame.lines[0..area_frame.line_count]) |line| {
                const head = spell_scene.vectorTransform(line.head, .{ 0, line.angle_y, 0 }, @splat(4096), root_vec);
                const tail = spell_scene.vectorTransform(line.tail, .{ 0, line.angle_y, 0 }, @splat(4096), root_vec);
                const a = @import("battle_camera").projectScene(block, head, .{}) orelse continue;
                const b = @import("battle_camera").projectScene(block, tail, .{}) orelse continue;
                result.append(.{ .vertices = .{ .{ .x = a.x, .y = a.y }, .{ .x = b.x, .y = b.y }, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 } }, .count = 2, .colors = @splat(line.color), .blend = .@"opaque", .depth = std.math.clamp(@as(i32, @intFromFloat(b.depth)) >> 2, 1, 509) });
            }
            for (area_frame.columns[0..area_frame.column_count]) |col| {
                appendColumn(result, block, root_vec, .{
                    .radius = col.lower.radius,
                    .top_radius = col.upper.radius,
                    .base_height = col.lower.height,
                    .height = col.upper.height,
                    .inner = col.upper.color,
                    .outer = col.lower.color,
                }, col.segments, col.angle_y, @splat(col.scale));
            }
            continue;
        }
        const binding = bundle.enemy_magic orelse continue;
        const graphic_frame = action.graphics(binding, art);
        for (graphic_frame.values[0..graphic_frame.count]) |graphic| {
            var world = action.root;
            for (graphic.position_q12, 0..) |local, axis| world[axis] += @as(i16, @truncate(local >> 12));
            var anchor = @import("battle_camera").projectScene(block, world, .{}) orelse continue;
            if (graphic.kind == .impact) {
                const id = self.progress.party[action.recipient].id;
                const pose = self.unite_vm.pose(action.recipient) orelse layout.actorLayout(self.*, action.recipient).source_pose orelse bundle.animations.find(id).?.find(0).?.frames[0].pose;
                anchor.x += @floatFromInt(art.center(id, pose) orelse continue);
            }
            const size = @divTrunc(scene_scale * graphic.size, 4096);
            const node = @import("battle_camera").Block{ .focus = .{ 0, 0, 0 }, .angles = .{ 0, 0, 0 }, .translation = .{ 0, 0, 1024 }, .scale = @splat(size) };
            const entry = packet.entries[graphic.entry];
            const corners = [4][3]i32{ .{ entry.dx, entry.dy, 0 }, .{ entry.dx + entry.w - 1, entry.dy, 0 }, .{ entry.dx, entry.dy + entry.h - 1, 0 }, .{ entry.dx + entry.w - 1, entry.dy + entry.h - 1, 0 } };
            var command = spell_scene.Command{ .vertices = undefined, .texture = graphic.entry, .tint = @splat(127), .depth = std.math.clamp(@as(i32, @intFromFloat(anchor.depth)) >> 2, 5, 379) };
            for (corners, 0..) |corner, index| {
                const offset = drops.rawProject(node, corner);
                command.vertices[index] = .{ .x = anchor.x + @as(f32, @floatFromInt(offset[0])), .y = anchor.y + @as(f32, @floatFromInt(offset[1])) };
            }
            result.append(command);
        }
    };
}
fn appendStatusIcons(self: *const State, result: *spell_scene.Frame) void {
    if (!self.hasStatusIcons()) return;
    const packet = self.spell_scenes.?;
    for (0..self.partyCount()) |actor| {
        if (self.departed[actor] and self.departures[actor] == null) continue;
        if (self.spellReaction(actor)) |response| if (!response.visible) continue;
        const anchors = packet.statusAnchors(self.progress.party[actor].id) orelse continue;
        const body = layout.actorLayout(self.*, actor);
        const source_pose = body.source_pose orelse continue;
        if (source_pose >= anchors.offsets.len) continue;
        const clock = self.status_icons[actor];
        for (packet.status_icons) |icon| {
            const index = @backingInt(icon.status);
            if (clock.active & (@as(u8, 1) << index) == 0) continue;
            var offset = anchors.offsets[source_pose];
            var scale: i32 = @intFromFloat(body.scale * 2048);
            var point = body.point;
            var opacity: u8 = 255;
            // Status graphics advance after the actor sweep, including their birth update.
            var entry_id = icon.entryAt(self.camera_ticks -% clock.started_at[index] +% 1);
            if (self.medicine_action) |item| if (item.affects(actor) and !item.interrupted(actor) and item.detached_status == index and item.ticks >= item.timing.target_start) {
                const age = item.ticks - item.timing.target_start;
                if (item.id == .needle and packet.needle_burst.len == 2) {
                    if (age == 0 or age > 10) continue;
                    entry_id = packet.needle_burst[if (age < 4) @as(usize, 0) else 1].entry;
                    opacity = 128;
                } else if (item.id == .antitoxin) {
                    const effect = self.rules.consumable(item.id).?.battle orelse continue;
                    if (age == 0 or age > effect.particles.len) continue;
                    const origin = item.particle_origins[actor] orelse continue;
                    const shift = effect.particles[age - 1][0];
                    const position_q0 = [3]i32{ @intFromFloat(@floor(origin.x + shift[0])), @intFromFloat(@floor(origin.y + shift[1])), @intFromFloat(@floor(origin.z + shift[2])) };
                    const block = layout.currentCamera(self.*);
                    const projected = @import("battle_camera").projectScene(block, position_q0, .{}) orelse continue;
                    point = .{ .x = projected.x * 2, .y = projected.y * 2, .depth = projected.depth };
                    scale = @divTrunc(block.scale[0] << 10, block.translation[2]);
                    offset = anchors.offsets[anchors.idle_pose];
                    entry_id = icon.entryAt(self.camera_ticks -% clock.started_at[index]);
                    opacity = 128;
                }
            };
            const x = point.x / 2 + @as(f32, @floatFromInt(@divTrunc(@as(i32, offset[0]) * scale, 4096)));
            const y = point.y / 2 + @as(f32, @floatFromInt(@divTrunc(@as(i32, offset[1]) * scale, 4096)));
            const entry = packet.entries[entry_id];
            var command = spell_scene.Command{ .vertices = undefined, .texture = entry_id, .opacity = opacity, .blend = .@"opaque", .depth = std.math.clamp(@as(i32, @intFromFloat(point.depth)) >> 2, 5, 379) };
            for (&command.vertices, 0..) |*vertex, corner| {
                const dx = entry.dx + if (corner & 1 != 0) entry.w else @as(i32, 0);
                const dy = entry.dy + if (corner >= 2) entry.h else @as(i32, 0);
                vertex.* = .{ .x = x + @as(f32, @floatFromInt((dx * scale) >> 12)), .y = y + @as(f32, @floatFromInt((dy * scale) >> 12)) };
            }
            result.append(command);
        }
    }
}
pub fn appendUniteImpacts(self: State, result: *spell_scene.Frame) void {
    const packet = self.spell_scenes orelse return;
    // shortcut: legacy Drops uses a separate atlas; bind mixed-atlas tails before enabling that overlap.
    if (self.hasDrops()) return;
    if (self.active) |effect| if (effect.unite_impact_effect) |visual| if (visual.started_at) |started| {
        if (impactEntry(packet, visual.clip, self.camera_ticks -% started + 1)) |entry| appendImpact(&self, result, entry, visual.origin_q12, .{ 0, 0 });
    };
    for (0..self.partyCount() + self.enemyCount()) |index| {
        const reaction = self.uniteReactionProgram(index) orelse continue;
        if (self.hp(index) == 0) continue;
        const instance = self.unite_reactions[index].?;
        const age = self.camera_ticks - instance.started_at;
        const pose = self.uniteReactionPose(index) orelse continue;
        const attachment = pose.impact_offset orelse continue;
        for (reaction.impacts) |spawn| {
            if (age < spawn.at) continue;
            const id = impactEntry(packet, spawn.animation, age - spawn.at + 1) orelse continue;
            var position = if (spawn.at == 0) instance.origin_q12 else spell_scene.unitePosition(reaction, instance.origin_q12, instance.home_q12, spawn.at - 1);
            for (0..3) |axis| position[axis] += @as(i32, spawn.offset[axis]) * 4096;
            appendImpact(&self, result, id, position, if (spawn.centered) attachment else [2]i8{ 0, 0 });
        }
    }
}
fn physicalWhite(self: *const State, index: usize) ?spell_scene.ReactionSample {
    const packet = self.spell_scenes orelse return null;
    if (index < self.partyCount()) return null;
    for (self.party_strikes) |maybe| if (maybe) |strike| {
        if (strike.target != index or strike.missed) continue;
        const timing = self.partyAttackTiming(strike.actor).?;
        const spec = timing.impacts orelse continue;
        if (strike.ticks < timing.impact_tick or strike.ticks >= timing.impact_tick + timing.target_release_delay) continue;
        const age = strike.ticks - timing.impact_tick;
        var white = false;
        for (spec.white) |event| if (event.at <= age) {
            white = event.enabled;
        };
        if (white) for (packet.physical_white_poses) |pose| if (std.mem.eql(u8, pose.id, self.enemy(index - self.partyCount()).id)) {
            return .{ .entry = pose.entry, .offset = .{ 0, 0 } };
        };
    };
    return null;
}
fn impactEntry(packet: *const spell_scene.Packet, animation: u8, elapsed: u32) ?u16 {
    for (packet.unite_impacts) |clip| if (clip.id == animation) {
        var left = elapsed;
        for (clip.frames) |frame| {
            if (left < frame.ticks) return frame.entry;
            left -= frame.ticks;
        }
    };
    return null;
}
fn appendImpact(self: *const State, result: *spell_scene.Frame, id: u16, position: [3]i32, center: [2]i8) void {
    const packet = self.spell_scenes.?;
    const point = layout.worldPoint(self.*, .{ .x = @floatFromInt(position[0] >> 12), .y = @floatFromInt(position[1] >> 12), .z = @floatFromInt(position[2] >> 12) });
    const scale = @import("battle_camera").scaleBlock(layout.currentCamera(self.*));
    const entry = packet.entries[id];
    const x = point.x / 2 + @as(f32, @floatFromInt(@as(i32, center[0]) + entry.dx)) * scale;
    const y = point.y / 2 + @as(f32, @floatFromInt(@as(i32, center[1]) + entry.dy)) * scale;
    const w = @as(f32, @floatFromInt(entry.w)) * scale;
    const h = @as(f32, @floatFromInt(entry.h)) * scale;
    if (result.count == result.commands.len) @panic("Impact command capacity exceeded");
    result.commands[result.count] = .{ .vertices = .{ .{ .x = x, .y = y }, .{ .x = x + w, .y = y }, .{ .x = x, .y = y + h }, .{ .x = x + w, .y = y + h } }, .texture = id, .blend = .@"opaque", .depth = @divTrunc(@as(i32, @intFromFloat(point.depth)) - 1, 4) };
    result.count += 1;
}
fn hasPhysicalImpacts(self: *const State) bool {
    const packet = self.spell_scenes orelse return false;
    if (self.hasDrops()) return false;
    for (self.party_strikes) |maybe| if (maybe) |strike| {
        const timing = self.partyAttackTiming(strike.actor).?;
        const impacts = timing.impacts orelse continue;
        const spawns = if (strike.critical) impacts.critical else impacts.ordinary;
        for (spawns, strike.impact_births[0..spawns.len]) |spawn, birth| {
            if (birth == null or strike.ticks < timing.impact_tick + spawn.at) continue;
            if (impactEntry(packet, spawn.animation, strike.ticks - timing.impact_tick - spawn.at + 1) != null) return true;
        }
    };
    return false;
}
fn appendPhysicalImpacts(self: *const State, result: *spell_scene.Frame) void {
    const packet = self.spell_scenes orelse return;
    if (self.hasDrops()) return;
    for (self.party_strikes) |maybe| if (maybe) |strike| {
        const timing = self.partyAttackTiming(strike.actor).?;
        const impacts = timing.impacts orelse continue;
        const spawns = if (strike.critical) impacts.critical else impacts.ordinary;
        for (spawns, strike.impact_births[0..spawns.len]) |spawn, maybe_birth| {
            const birth = maybe_birth orelse continue;
            if (strike.ticks < timing.impact_tick + spawn.at) continue;
            const id = impactEntry(packet, spawn.animation, strike.ticks - timing.impact_tick - spawn.at + 1) orelse continue;
            appendImpact(self, result, id, birth.position_q12, birth.center);
        }
    };
}
pub fn issueSpellCameraRequest(self: *State, update: u16) void {
    if (!self.hasSpellScene()) return;
    const controller = if (self.actor_camera) |*value| value else return;
    const program = self.spell_scenes.?.spells[self.active.?.scene.?.spell].program.?;
    for (program.cameras) |event| {
        if (event.at > update) break;
        if (event.at != update) continue;
        controller.requestBlock(event.target, event.updates) catch {
            self.replay_unsupported = .coordinator_action;
        };
        break;
    }
}
pub fn advanceSpellScene(self: *State, action_update: u16) void {
    if (!self.hasSpellScene()) return;
    const program = self.spell_scenes.?.spells[self.active.?.scene.?.spell].program.?;
    const update = @min(action_update, program.duration);
    if (program.actor_motion) |motion| {
        const instance = &self.active.?.scene.?;
        for (instance.targets[0..instance.target_count]) |*target| {
            if (!target.movable or target.actor == null) continue;
            if (instance.elapsed < motion.start and update >= motion.start) {
                const position = layout.ambientWorldPosition(self, target.actor.?);
                target.motion_origin = .{ @intFromFloat(@floor(position.x * 4096)), @intFromFloat(@floor(position.y * 4096)), @intFromFloat(@floor(position.z * 4096)) };
            }
            if (instance.elapsed < motion.returning and update >= motion.returning) {
                const position = layout.ambientWorldPosition(self, target.actor.?);
                target.return_origin = .{ @intFromFloat(@floor(position.x * 4096)), @intFromFloat(@floor(position.y * 4096)), @intFromFloat(@floor(position.z * 4096)) };
            }
        }
    }
    var local = systems.Draws{ .prng = self.random };
    self.active.?.scene.?.advance(self.spell_scenes.?, update, self.replay_draws orelse &local) catch |err| {
        if (err == error.RandomInputExhausted) self.replay_exhausted = true else self.replay_unsupported = .coordinator_action;
        return;
    };
    if (program.actor_motion) |motion| for (self.active.?.scene.?.targets[0..self.active.?.scene.?.target_count]) |target| {
        const index = target.actor orelse continue;
        const transformed = spell_scene.actorTransform(program, target, update) catch {
            self.replay_unsupported = .coordinator_action;
            return;
        };
        if (transformed) |sample| {
            self.actor_sizes[index] = sample.size;
            const home = target.home orelse target.position;
            if (update >= motion.start + motion.updates - 1 and update < motion.returning) self.actor_world_offsets[index] = .{ .x = @floatFromInt(motion.destination[0] - home[0]), .y = @floatFromInt(motion.destination[1] - home[1]), .z = @floatFromInt(motion.destination[2] - home[2]) };
            if (update >= motion.returning + motion.updates - 1) self.actor_world_offsets[index] = .{ .x = 0, .y = 0, .z = 0 };
        }
    };
    if (self.replay_draws == null) self.random = local.prng.?;
}
pub fn holdSpellCamera(self: *State) void {
    if (self.hasSpellScene()) self.source_camera_hold = layout.cameraForTransition(self);
}
pub fn uniteDamageAmount(self: State, index: usize) ?u32 {
    const effect = self.active orelse return null;
    if (effect.kind != .unite or index >= self.partyCount() + self.enemyCount()) return null;
    if (self.hasLiveUniteActors() and self.unite_vm.impact_at[effect.actor] == null) return null;
    const elapsed = self.effectTicks();
    const impact = self.impactTick();
    if (elapsed < impact or elapsed - impact >= 30) return null;
    if (effect.affected != 0) return if (effect.affected & (@as(u16, 1) << @intCast(index)) != 0) effect.amounts[index] else null;
    return if (effect.target == index) effect.amount else null;
}
