const std = @import("std");
const status = @import("battle_status");
const damage_rules = @import("battle_damage");
const presentation_flow = @import("battle_presentation_flow");
const turn = @import("battle_turn");
const battle_systems = @import("battle_systems");
const technique_systems = battle_systems.techniques;
const combat_effects = @import("combat_systems").effects;
const layout = @import("battle_layout.zig");
const drops = @import("battle_drops.zig");
const spell_scene = @import("battle_spell_scene.zig");
const systems = @import("battle_rules");
const battle = @import("battle.zig");
const camera = @import("battle_camera");
const types_mod = @import("battle_types.zig");
const State = battle.State;
const priority = damage_rules.priority;
const Action = types_mod.Action;
const Coordinator = types_mod.Coordinator;
const antSpecial = types_mod.antSpecial;

pub fn sharedPartyMelee(self: *const State) bool {
    const bundle = self.unite_actors orelse return false;
    const packet = bundle.counterPacket() orelse return false;
    return packet.party_melee != null;
}
pub fn sourceRounds(self: *const State) bool {
    if (self.content.world_art != null) return true;
    if (self.content.round_start != null and self.sharedPartyMelee()) return true;
    for (0..self.enemyCount()) |index| if (self.enemy(index).action_policy == .front_projectile or self.enemy(index).action_policy == .source_projectile) return true;
    return false;
}

fn sourceEnemyActor(self: *const State, actor: usize) bool {
    if (actor < self.partyCount()) return false;
    return self.hasSourceAnt(actor) or switch (self.enemy(actor - self.partyCount()).action_policy) {
        .source_melee, .source_magic, .source_projectile, .source_ninja, .source_dagon, .source_whip_wolf, .source_holly_fairy, .source_sorcerer, .source_siren, .source_earth_golem, .source_creeper, .source_shadow_man, .source_mirage_f, .source_mirage_h => true,
        else => false,
    };
}
/// The round boundary handles departures and front vacancies before HP and status clocks.
pub fn applyRoundBoundaryStatuses(self: *State) void {
    status.applyRoundBoundaryStatuses(self);
}

pub fn beginDeparture(self: *State, actor: usize) void {
    if (!self.participates(actor) or self.knockout_pending[actor] or self.revivals[actor] != null) return;
    const origin = layout.worldPosition(self, actor);
    self.departures[actor] = .{ .started_at = self.camera_ticks, .origin = origin };
    self.departed[actor] = true;
}

pub fn resolveTick(self: *State) void {
    turn.resolveTick(self);
}

pub fn attachEffects(self: *State, packet: *const combat_effects.Packet) void {
    self.effects = .{ .packet = packet };
}

pub fn beginCastPresentation(self: *State, spell_id: []const u8) void {
    presentation_flow.beginCastPresentation(self, spell_id);
}
pub fn beginAttackPresentation(self: *State, actor: usize) void {
    presentation_flow.beginAttackPresentation(self, actor);
}
pub fn advancePresentation(self: *State, boundary: u16) void {
    presentation_flow.advancePresentation(self, boundary);
}
pub fn effectFrame(self: *const State, boundary: u16) ?combat_effects.Frame {
    return presentation_flow.effectFrame(self, boundary);
}

pub fn queuedSpell(self: *const State, actor: usize, cast: anytype) ?*const systems.Spell {
    if (!self.canCast(actor, cast.index)) return null;
    const spell = &self.content.systems.?.spells[cast.index];
    if (cast.target >= (if (spell.allies) self.partyCount() else self.enemyCount())) return null;
    return spell;
}

pub fn beginSpellAction(self: *State, actor: usize, cast: anytype) bool {
    return startSpellAction(self, actor, cast) == .started;
}

const ActionStart = enum { started, wait, rejected };

pub fn startSpellAction(self: *State, actor: usize, cast: anytype) ActionStart {
    const spell = queuedSpell(self, actor, cast) orelse return .rejected;
    const requested = cast.target + if (spell.allies) @as(usize, 0) else self.partyCount();
    // shortcut: single enemy spells share the trial's first-survivor retarget policy.
    const target = if (!spell.allies and (spell.group or !self.participates(requested))) self.firstLiving(false) orelse return .rejected else requested;
    if (self.coordinatorLocked(target) and target != actor) return .wait;
    const initial_camera = layout.cameraForTransition(self);
    self.active = .{ .actor = actor, .target = target, .kind = .cast, .spell = cast.index, .retargeted_from = if (target != requested) requested else null };
    if (self.spell_scenes) |packet| if (packet.indexOf(spell.id)) |scene_id| {
        const controller = self.actor_camera orelse (camera.ActorController.init(initial_camera) catch {
            self.replay_unsupported = .coordinator_action;
            return .rejected;
        });
        const caster_position = layout.worldPosition(self, actor);
        const target_position = layout.worldPosition(self, target);
        var party_targets: [6]spell_scene.Target = undefined;
        for (0..self.partyCount()) |member| {
            const position = layout.worldPosition(self, member);
            party_targets[member] = .{ .actor = member, .position = .{ @intFromFloat(@round(position.x)), @intFromFloat(@round(position.y)), @intFromFloat(@round(position.z)) } };
        }
        var local = systems.Draws{ .prng = self.random };
        var instance = spell_scene.Instance.beginForParty(packet, scene_id, .{ @intFromFloat(@round(caster_position.x)), @intFromFloat(@round(caster_position.y)), @intFromFloat(@round(caster_position.z)) }, .{ @intFromFloat(@round(target_position.x)), @intFromFloat(@round(target_position.y)), @intFromFloat(@round(target_position.z)) }, initial_camera, self.replay_draws orelse &local, party_targets[0..self.partyCount()]) catch |err| {
            if (err == error.RandomInputExhausted) self.replay_exhausted = true else self.replay_unsupported = .coordinator_action;
            return .rejected;
        };
        if (self.replay_draws == null) self.random = local.prng.?;
        const target_pose = layout.actorLayout(self.*, target).sprite;
        // shortcut: composed-pose centering; qualify multi-piece targets before promoting their previews.
        instance.target_center = .{ @divTrunc(target_pose.rect.w, 2) - target_pose.anchor_x, @divTrunc(target_pose.rect.h, 2) - target_pose.anchor_y };
        instance.target_idle_center = instance.target_center;
        instance.target_height = @intCast(std.math.clamp(target_pose.rect.h, 0, 255));
        const target_profile_id = if (target < self.partyCount()) self.progress.party[target].id else self.enemy(target - self.partyCount()).id;
        for (packet.hurt_poses) |pose| if (std.mem.eql(u8, pose.id, target_profile_id)) {
            if (pose.sprite_height) |height| instance.target_height = height;
            break;
        };
        if (packet.spells[scene_id].program.?.reaction != null and packet.spells[scene_id].program.?.center_after_reaction) {
            const target_id = if (target < self.partyCount()) self.progress.party[target].id else self.enemy(target - self.partyCount()).id;
            for (packet.hurt_poses) |pose| if (std.mem.eql(u8, pose.id, target_id)) {
                if (pose.idle_center) |center| instance.target_idle_center = .{ center[0], center[1] };
                if (pose.center) |center| instance.target_center = .{ center[0], center[1] };
                break;
            };
        }
        if (spell.group) {
            // shortcut: capture recipients while spell actions are serialized; resample for concurrent actions.
            for (0..self.partyCount() + self.enemyCount()) |recipient| {
                if ((recipient < self.partyCount()) != spell.allies or (spell.kind != .revive and !self.participates(recipient))) continue;
                if (packet.spells[scene_id].program.?.actor_motion) |motion| {
                    if (motion.exclude_airborne and recipient >= self.partyCount() and self.enemy(recipient - self.partyCount()).airborne == null) {
                        self.active.?.kind = .unavailable;
                        return .started;
                    }
                }
                const position = layout.worldPosition(self, recipient);
                const pose = layout.actorLayout(self.*, recipient).sprite;
                var center = [2]i32{ @divTrunc(pose.rect.w, 2) - pose.anchor_x, @divTrunc(pose.rect.h, 2) - pose.anchor_y };
                const id = if (recipient < self.partyCount()) self.progress.party[recipient].id else self.enemy(recipient - self.partyCount()).id;
                for (packet.hurt_poses) |art| if (std.mem.eql(u8, art.id, id)) {
                    const known = if (packet.spells[scene_id].program.?.center_after_reaction) art.center else art.idle_center;
                    if (known) |v| center = .{ v[0], v[1] };
                    break;
                };
                const home = layout.homePosition(self, recipient);
                const motion = packet.spells[scene_id].program.?.actor_motion;
                const movable = if (motion) |m| (!m.exclude_protected or self.protection[recipient] == 0) and (!m.exclude_airborne or recipient < self.partyCount() or !(self.enemy(recipient - self.partyCount()).airborne orelse false)) else true;
                instance.targets[instance.target_count] = .{ .formation_slot = @intCast(if (recipient < self.partyCount()) recipient else recipient - self.partyCount()), .actor = recipient, .home = .{ @intFromFloat(@round(home.x)), @intFromFloat(@round(home.y)), @intFromFloat(@round(home.z)) }, .size_base = self.actor_sizes[recipient], .movable = movable, .position = .{ @intFromFloat(@round(position.x)), @intFromFloat(@round(position.y)), @intFromFloat(@round(position.z)) }, .center = center };
                instance.target_count += 1;
            }
        }
        instance.flicker_phase = @truncate(self.presentation_tick);
        self.actor_camera = controller;
        self.active.?.scene = instance;
        self.source_camera_return = null;
    };
    if (!self.hasSpellScene() and self.drops_art != null and std.mem.eql(u8, spell.id, "spell_9")) {
        if (self.hasUniteReactionEffects()) {
            self.replay_unsupported = .coordinator_action;
            return .rejected;
        }
        var instance = drops.Instance{ .draws = undefined, .caster = undefined, .target = undefined };
        for (&instance.draws) |*draw| draw.* = self.roll();
        const caster_position = layout.worldPosition(self, actor);
        const target_position = layout.worldPosition(self, target);
        instance.caster = .{ @intFromFloat(@round(caster_position.x)), @intFromFloat(@round(caster_position.y)), @intFromFloat(@round(caster_position.z)) };
        instance.target = .{ @intFromFloat(@round(target_position.x)), @intFromFloat(@round(target_position.y)), @intFromFloat(@round(target_position.z)) };
        self.active.?.drops = instance;
    }
    self.beginCastPresentation(spell.id);
    return .started;
}

pub fn beginUniteAction(self: *State, actor: usize, target_index: usize) bool {
    return self.startUniteAction(actor, target_index) == .started;
}

pub fn startUniteAction(self: *State, actor: usize, target_index: usize) ActionStart {
    // The source dispatcher waits for every actor lock before installing a Unite.
    for (0..self.partyCount() + self.enemyCount()) |index| if (self.coordinatorLocked(index)) return .wait;
    if (target_index >= self.enemyCount()) return .rejected;
    const target = if (self.enemy_hp[target_index] > 0) target_index + self.partyCount() else self.firstLiving(false) orelse return .rejected;
    if (self.integration) |integration| {
        const boundary = self.uniteBoundaryFor(actor) orelse return .wait;
        const record = integration.host.uniteCatalogue().recordAt(boundary.record_index) orelse return .rejected;
        for (boundary.participantsSlice()) |participant| if (battle.revival.committedPartyInactive(self.*, participant)) return .rejected;
        var listed = false;
        var needs_reaction = false;
        var complete_tracks = true;
        for (boundary.participantsSlice()) |participant| {
            if (participant == actor) listed = true;
            if (self.partyProfile(participant).uniteTrack(boundary.record_index)) |track| {
                needs_reaction = needs_reaction or track.reaction_on_hit;
            } else complete_tracks = false;
            self.acted[participant] = true;
            if (self.content.world_art) |art| {
                const profile = self.partyProfile(participant);
                if (profile.uniteTrack(boundary.record_index)) |track| {
                    if (participant >= art.actors.len or !std.mem.eql(u8, art.actors[participant].id, profile.id)) {
                        self.replay_unsupported = .coordinator_action;
                        return .wait;
                    }
                    for (track.attack) |frame| if (frame.source_pose == null or frame.source_pose.? >= art.actors[participant].poses.len) {
                        self.replay_unsupported = .coordinator_action;
                        return .wait;
                    };
                }
            }
        }
        if (!listed) return .rejected;
        if (self.unite_actors) |bundle| if (bundle.find(boundary.record_index)) |binding| {
            for (binding.members) |member| {
                if (binding.dispatch_after == null) continue;
                needs_reaction = needs_reaction or member.reaction_on_hit;
                if (member.reaction_on_hit and !self.hasUniteReactionBinding(boundary.record_index, member.reaction_variant, target)) {
                    self.replay_unsupported = .coordinator_action;
                    return .wait;
                }
                if (member.reaction_group) for (0..self.enemyCount()) |enemy_index| {
                    const recipient = self.partyCount() + enemy_index;
                    if (self.hp(recipient) > 0 and !self.hasUniteReactionBinding(boundary.record_index, member.reaction_variant, recipient)) {
                        self.replay_unsupported = .coordinator_action;
                        return .wait;
                    }
                };
            }
        };
        const live_binding = self.unite_actors != null and self.unite_actors.?.find(boundary.record_index).?.dispatch_after != null;
        const skips_damage_reaction = live_binding and (!self.unite_actors.?.find(boundary.record_index).?.damage_reaction or self.unite_actors.?.find(boundary.record_index).?.controller != null);
        if ((needs_reaction or live_binding) and ((!complete_tracks and !live_binding) or (!skips_damage_reaction and boundary.sequence == null and !self.hasUniteReactionBinding(boundary.record_index, 0, target)))) {
            self.replay_unsupported = .coordinator_action;
            return .wait;
        }
        if (live_binding and boundary.sequence != null) for (0..self.enemyCount()) |enemy| {
            const recipient = self.partyCount() + enemy;
            if (!self.enemyInactive(enemy) and !self.coordinatorLocked(recipient) and !self.hasUniteReactionBinding(boundary.record_index, 0, recipient)) {
                self.replay_unsupported = .coordinator_action;
                return .wait;
            }
        };
        var partner: ?usize = null;
        for (boundary.participantsSlice()) |participant| if (participant != actor) {
            partner = participant;
            break;
        };
        if (self.unite_actors != null and (boundary.record_index <= 1 or self.unite_actors.?.find(boundary.record_index).?.dispatch_after != null)) {
            self.beginUniteActors(boundary.record_index, actor, target) catch {
                self.replay_unsupported = .coordinator_action;
                return .wait;
            };
        }
        if (self.unite_boundaries[actor]) |*started| {
            if (record.target_rule == .individual) {
                const target_id: i16 = @intCast(target + 1);
                if (started.target != target_id) {
                    started.retargeted_from = started.retargeted_from orelse started.target;
                    started.target = target_id;
                }
                self.last_targets[actor] = @intCast(target_id);
            }
            if (started.sequence) |*queue| {
                // The source snapshots target eligibility when the Unite starts.
                for (0..self.enemyCount()) |enemy| {
                    queue.pending[enemy] = !self.enemyInactive(enemy) and !self.coordinatorLocked(self.partyCount() + enemy);
                }
            }
        }
        self.active = .{ .actor = actor, .target = target, .kind = .unite, .partner = partner, .unite_boundary = true, .retargeted_from = if (target != target_index + self.partyCount()) target_index + self.partyCount() else null };
        return .started;
    }
    if (!self.canUnite(actor)) return .rejected;
    const partner = self.unitePartner(actor) orelse return .rejected;
    self.acted[partner] = true;
    self.active = .{ .actor = actor, .target = target, .kind = .unite, .partner = partner, .amount = (self.resolvePhysicalDamage(actor, target, self.roll(), false) + self.resolvePhysicalDamage(partner, target, self.roll(), false)) * self.uniteDefinition(actor).?.power, .retargeted_from = if (target != target_index + self.partyCount()) target_index + self.partyCount() else null };
    return .started;
}

pub fn beginRuneAttack(self: *State, actor: usize, requested: usize) bool {
    return startRuneAttack(self, actor, requested) == .started;
}

pub fn startRuneAttack(self: *State, actor: usize, requested: usize) ActionStart {
    if (!self.canPhysicalRune(actor)) return .rejected;
    if (requested >= self.enemyCount()) return .rejected;
    const technique = self.physicalRune(actor);
    const target = if (self.enemy_hp[requested] > 0) requested + self.partyCount() else self.firstLiving(false) orelse return .rejected;
    if (self.coordinatorLocked(target)) return .wait;
    if (self.unite_actors) |bundle| if (bundle.physical != null) {
        self.beginSourcePhysicalRune(actor, target) catch |err| {
            if (err == error.RandomInputExhausted) self.replay_exhausted = true else self.replay_unsupported = .coordinator_action;
            return .rejected;
        };
        self.active.?.retargeted_from = if (target != requested + self.partyCount()) requested + self.partyCount() else null;
        return .started;
    };
    // shortcut: legacy packages retain ordinary motion until regenerated with the physical actor bundle.
    var numerator: u16 = if (technique) |value| value.power * 10 else 10;
    if (self.integration != null) {
        // The class-1 handlers store a numerator at 0x8017A008
        // and 0x800F881C applies `damage * numerator / 10`; class 1 skips
        // the magic charge service.
        const byte = self.runeByteFor(actor) orelse return .rejected;
        const planned = technique_systems.physical.plan(.{
            .rune_byte = byte,
            .actor_can_act = self.canPhysicalRune(actor),
            .target = target - self.partyCount(),
            .target_live = self.enemy_hp[target - self.partyCount()] > 0,
        }) catch return .rejected;
        switch (planned) {
            .strike => |strike| numerator = strike.numerator,
            .unsupported => return .rejected,
        }
    }
    const base = self.resolvePhysicalDamage(actor, target, self.roll(), false);
    self.active = .{ .actor = actor, .target = target, .kind = .attack, .rune_attack = true, .recovery_rounds = if (technique) |value| value.recovery_rounds else 0, .amount = technique_systems.physical.damage(numerator, base), .retargeted_from = if (target != requested + self.partyCount()) requested + self.partyCount() else null };
    return .started;
}

pub fn nextAction(self: *State) void {
    if (self.firstLiving(true) == null) {
        if (!self.hasUniteReturns() and !self.hasPendingRevival()) self.phase = .defeat;
        return;
    }
    if (self.firstLiving(false) == null) {
        if (!self.hasUniteReturns() and !self.hasPendingRevival()) {
            self.commitRewards();
            self.phase = .victory;
        }
        return;
    }
    var selected = self.pending_party_actor;
    if (selected) |actor| {
        if (!self.participates(actor) or self.acted[actor]) {
            self.pending_party_actor = null;
            selected = null;
        } else if (self.coordinatorLocked(actor)) return;
    }
    if (selected == null) {
        var first_party: ?usize = null;
        var best: i32 = 0;
        for (0..self.partyCount() + self.enemyCount()) |index| {
            if (!self.participates(index) or self.acted[index]) continue;
            if (index < self.partyCount()) if (self.actions[index]) |action| if (action == .assist and action.assist < self.partyCount()) {
                const owner = self.actions[action.assist];
                if (!self.acted[action.assist] or owner == null or owner.? != .unite) continue;
            };
            if (self.coordinatorLocked(index)) continue;
            if (first_party == null and index < self.partyCount() and self.asleep[index] == 0) first_party = index;
            const value = priority(self.stats(index).speed, self.roll());
            if (selected == null or value > best) {
                selected = index;
                best = value;
            }
        }
        // The original performs ordinary priority rolls before Spark's party-order override.
        if (self.spark_pending) {
            if (first_party) |member| selected = member else self.spark_pending = false;
        }
    }
    const actor = selected orelse {
        if (self.hasUniteReturns() or self.hasPendingRevival()) return;
        self.applyRoundBoundaryStatuses();
        if (self.firstLiving(true) == null and !self.hasPendingRevival()) {
            self.phase = .defeat;
            return;
        }
        self.round += 1;
        self.actions = @splat(null);
        if (self.hasPendingRevival()) self.round_menu_pending = true else self.openAfterRound();
        return;
    };
    if (actor >= self.partyCount() and self.asleep[actor] == 0 and self.enemy(actor - self.partyCount()).action_policy == .unsupported) {
        self.replay_unsupported = .enemy_policy;
        return;
    }
    if (actor < self.partyCount() and for (self.partyCount()..self.partyCount() + self.enemyCount()) |enemy| {
        if (sourceEnemyActor(self, enemy)) break true;
    } else false) {
        self.action_ticks = 0;
        self.coordinator = .{ .stage = .dispatch, .current_actor = actor, .elapsed = 0 };
        self.advanceCoordinator();
        return;
    }
    if (actor < self.partyCount() and self.actions[actor] != null and self.actions[actor].? == .unite) {
        for (0..self.partyCount() + self.enemyCount()) |index| if (self.coordinatorLocked(index)) {
            self.pending_party_actor = actor;
            return;
        };
    }
    self.pending_party_actor = null;
    self.acted[actor] = true;
    self.action_ticks = 0;
    if (self.asleep[actor] > 0) {
        self.active = .{ .actor = actor, .target = actor, .kind = .sleeping };
        return;
    }
    if (sourceEnemyActor(self, actor)) {
        self.coordinator = .{ .stage = .dispatch, .current_actor = actor, .elapsed = 0 };
        self.sourceEnemyDecision(actor);
        return;
    }
    if (actor >= self.partyCount() and self.enemy(actor - self.partyCount()).action_policy == .front_projectile) {
        _ = self.frontProjectileDecision(actor);
        self.advanceFrontProjectiles();
        return;
    }
    if (actor >= self.partyCount() and (self.enemy(actor - self.partyCount()).action_policy == .rabbit or self.enemy(actor - self.partyCount()).action_policy == .source_rabbit)) {
        self.rabbitDecision(actor);
        return;
    }
    if (actor >= self.partyCount() and (self.enemy(actor - self.partyCount()).action_policy == .commander or self.enemy(actor - self.partyCount()).action_policy == .source_commander)) {
        self.commanderDecision(actor);
        return;
    }
    if (actor >= self.partyCount() and self.enemy(actor - self.partyCount()).action_policy == .roc) {
        self.rocDecision(actor);
        return;
    }
    if (self.content.world_art != null and actor < self.partyCount()) {
        self.replay_unsupported = .coordinator_action;
        return;
    }
    var enemy_special = false;
    const action: Action = if (actor < self.partyCount()) self.actions[actor].? else blk: {
        const target = self.chooseEnemyTarget(actor - self.partyCount()) orelse {
            self.active = .{ .actor = actor, .target = actor, .kind = .unavailable };
            return;
        };
        enemy_special = self.enemy(actor - self.partyCount()).action_policy == .ant_double_strike and antSpecial(self.roll());
        if (self.replay_exhausted) return;
        if (!enemy_special and self.enemy(actor - self.partyCount()).action_policy == .ant_double_strike) {
            if (self.unite_actors) |bundle| if (bundle.counterPacket()) |packet| {
                if (packet.meleeEnemy(self.enemy(actor - self.partyCount()).id) != null) {
                    _ = self.sourceEnemyAttack(actor, target);
                    return;
                }
            };
        }
        break :blk .{ .attack = target };
    };
    switch (action) {
        .assist => |owner| {
            if (owner >= self.partyCount() or !self.acted[owner]) self.replay_unsupported = .coordinator_action;
        },
        .spell, .unite, .rune_attack => {
            const launched = switch (action) {
                .spell => |cast| startSpellAction(self, actor, cast),
                .unite => |target| self.startUniteAction(actor, target),
                .rune_attack => |target| startRuneAttack(self, actor, target),
                else => unreachable,
            };
            switch (launched) {
                .started => {},
                .wait => {
                    self.acted[actor] = false;
                    self.pending_party_actor = actor;
                },
                .rejected => if (action == .unite) {
                    self.discardUnite(actor);
                } else {
                    self.active = .{ .actor = actor, .target = actor, .kind = .unavailable };
                },
            }
        },
        .defend => self.active = .{ .actor = actor, .target = actor, .kind = .defend },
        .item => |item| self.active = .{ .actor = actor, .target = item.target, .kind = .item, .item_id = item.id },
        .attack => |requested| self.beginAttack(actor, requested, enemy_special, null),
    }
}
pub fn commanderDecision(self: *State, actor: usize) void {
    self.pending_enemy_actor = null;
    if (self.enemy(actor - self.partyCount()).action_policy == .source_commander and !self.hasSourceCommander(actor)) {
        self.replay_unsupported = .enemy_policy;
        return;
    }
    var group = false;
    if (self.enemyRow(actor - self.partyCount()) == .back) for (self.partyCount()..self.partyCount() + self.enemyCount()) |ally| {
        if (self.participates(ally) and !self.acted[ally] and !self.coordinatorLocked(ally) and self.enemyRow(ally - self.partyCount()) == .front) {
            group = true;
            break;
        }
    };
    if (group) {
        if (self.hasSourceCommander(actor)) {
            self.beginSourceCommander(actor, null) catch {
                self.replay_unsupported = .enemy_policy;
            };
            return;
        }
        var selected: ?usize = null;
        for (self.partyCount()..self.partyCount() + self.enemyCount()) |ally| {
            const target = self.formation[ally - self.partyCount()];
            if (ally == actor or !self.participates(ally) or self.acted[ally] or self.coordinatorLocked(ally) or target >= self.partyCount() or !self.participates(target) or self.coordinatorLocked(target)) continue;
            // shortcut: one witnessed Squirrel overlaps the Commander; other rosters need their own complete source tracks.
            if (selected != null or self.enemy(ally - self.partyCount()).ordered_attack == null) {
                self.replay_unsupported = .enemy_policy;
                return;
            }
            selected = ally;
        }
        const ally = selected orelse {
            self.replay_unsupported = .enemy_policy;
            return;
        };
        self.acted[actor] = true;
        self.active = .{ .actor = actor, .target = self.formation[ally - self.partyCount()], .kind = .group_order, .ordered = .{ .actor = ally } };
        self.coordinator = .{ .current_actor = actor };
        self.action_ticks = 1;
        return;
    }
    self.acted[actor] = false;
    for (0..self.partyCount()) |target| {
        if (!self.participates(target) or self.coordinatorLocked(target) or self.roll() % 100 < 51) continue;
        if (self.hasSourceCommander(actor)) {
            self.beginSourceCommander(actor, target) catch {
                self.replay_unsupported = .enemy_policy;
            };
            return;
        }
        self.acted[actor] = true;
        self.active = .{ .actor = actor, .target = target, .kind = .status_attack };
        self.action_ticks = 1;
        return;
    }
    self.pending_enemy_actor = actor;
}
