const std = @import("std");
const damage_rules = @import("battle_damage");
const dispatch = @import("battle_turn_dispatch.zig");
const battle = @import("battle.zig");
const types_mod = @import("battle_types.zig");
const State = battle.State;
const hitsWithAccuracyPenalty = damage_rules.hitsWithAccuracyPenalty;
const critical = damage_rules.critical;
const priority = damage_rules.priority;
const PartyAttackTiming = types_mod.PartyAttackTiming;
const Coordinator = types_mod.Coordinator;

const CompletionCheckpoint = enum { before_dispatch, after_action, round_ready };
const ordinary_victory_wait_ticks = 31;

/// The source round gate gives victory precedence in a simultaneous knockout and starts its
/// countdown after revival and playback settle. Legacy checkpoints give defeat precedence.
/// Before legacy dispatch, either terminal result waits for playback. At action end and the
/// source round gate, only victory waits for playback. Any terminal result waits for revival.
pub fn advanceBattleCompletion(self: *State, checkpoint: CompletionCheckpoint) types_mod.BattleCompletion {
    const outcome = self.combatOutcome(if (checkpoint == .round_ready) .victory else .defeat);
    if ((outcome != .ongoing or checkpoint != .before_dispatch) and self.hasPendingRevival()) return .waiting_for_revival;
    if (outcome == .ongoing) return .resolving;
    if ((outcome == .victory or checkpoint == .before_dispatch) and self.hasUniteReturns()) return .waiting_for_animation;

    if (checkpoint == .round_ready) {
        const clock = &self.coordinator.?;
        self.action_ticks = clock.elapsed + 1;
        if (outcome == .victory) {
            clock.elapsed = self.action_ticks;
            clock.stage = .victory_wait;
            clock.remaining = ordinary_victory_wait_ticks - 1;
            return .rewards_pending;
        }
    }
    finishBattle(self, outcome);
    return .complete;
}

fn finishBattle(self: *State, outcome: types_mod.BattleOutcome) void {
    switch (outcome) {
        .ongoing => unreachable,
        .victory => {
            self.commitRewards();
            self.phase = .victory;
        },
        .defeat => self.phase = .defeat,
    }
    self.coordinator = null;
}

pub fn openAfterRound(self: *State) void {
    if (self.content.encounters[self.encounter].scripted_finish) |finish| {
        if (self.firstLiving(true)) |actor| {
            if (self.round == @as(u32, finish.after_round) + 1) {
                self.coordinator = .{ .stage = .victory_wait, .remaining = finish.wait_ticks - 1, .current_actor = actor };
                return;
            }
        }
    }
    self.enterRoundMenu();
}

pub fn coordinatorLocked(self: *const State, actor: usize) bool {
    for (self.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
        if (playback.action == null and (actor == playback.attacker or actor == playback.defender or (playback.guard != null and playback.guard.? == actor))) return true;
        if (actor == playback.attacker and playback.knockout_at != null and !playback.attacker_done) return true;
    };
    for (self.unite_vm.physical_actions) |maybe| if (maybe) |playback| {
        if (playback.action == null and (actor == playback.owner or actor == playback.recipient)) return true;
        if (actor == playback.recipient and playback.knockout_at != null and !playback.recipient_done) return true;
    };
    if (actor < self.unite_vm.scripted_actors.len and self.unite_vm.scripted_actors[actor] != null and self.unite_vm.actors[actor].highlights != 0) return true;
    if (actor < self.partyCount() and self.party_knockouts[actor].revival != null) return true;
    const unite_reaction = if (actor < self.unite_reactions.len) self.unite_reactions[actor] else null;
    if (unite_reaction != null and self.uniteRecipientLocked(actor)) return true;
    const separate_knockout = if (unite_reaction) |reaction| reaction.knockout_ticks != 0 else false;
    if (self.uniteReturnFor(actor) != null) return true;
    for (self.unite_returns) |maybe| if (maybe) |tail| if (tail.target == actor and !tail.target_released and !separate_knockout) return true;
    for (self.front_projectiles) |maybe| if (maybe) |shot| if ((shot.actor == actor and !shot.owner_released) or (shot.target == actor and !shot.target_released)) return true;
    if (self.medicine_action) |item| if ((item.actor == actor and !item.owner_released) or (item.affects(actor) and !item.interrupted(actor) and item.ticks >= item.timing.target_start and !item.target_released)) return true;
    for (self.party_strikes) |maybe| if (maybe) |strike| if ((strike.actor == actor and !strike.owner_released) or (strike.target == actor and !strike.target_released)) return true;
    const effect = self.active orelse return false;
    if (effect.ordered) |child| {
        return (actor == effect.actor and !effect.owner_released) or (actor == child.actor and child.started) or (actor == effect.target and child.started and !child.target_released);
    }
    if (effect.protector) |guard| {
        if (actor == guard) return !effect.protector_released;
        if (actor == effect.target) return !effect.ward_released;
    }
    if (effect.counter_attack) return false;
    return self.isActing(actor) or (effect.target == actor and !effect.target_released and (effect.kind != .unite or !separate_knockout));
}
pub fn coordinatorActed(self: *const State, actor: usize) bool {
    for (self.front_projectiles) |maybe| if (maybe) |shot| if (shot.target == actor and !shot.target_released) return false;
    if (self.acted[actor]) return true;
    if (actor < self.partyCount() and self.party_knockouts[actor].pending) return false;
    // HP-zero targets keep their pending turn/lock until the reaction commits their down state.
    if (self.active) |effect| if (effect.damage_at_impact and self.enemy(effect.actor - self.partyCount()).action_policy == .roc) {
        if (effect.protector == actor and !effect.protector_released) return false;
        if (effect.target == actor and !effect.target_released) return false;
    };
    if (self.active) |effect| if (effect.ordered) |child| if (effect.target == actor and child.started and !child.target_released) return false;
    return !self.participates(actor);
}
pub fn primaryEffectBusy(self: *const State, actor: usize) bool {
    if (self.active == null) return false;
    if (actor >= self.partyCount()) return self.enemy(actor - self.partyCount()).action_policy != .front_projectile;
    const action = self.actions[actor] orelse return false;
    return action == .spell or action == .rune_attack or action == .unite or action == .assist;
}

fn commandOwner(self: *const State, actor: usize) usize {
    if (actor < self.partyCount()) if (self.actions[actor]) |action| if (action == .assist and action.assist < self.partyCount() and !self.acted[action.assist]) return action.assist;
    return actor;
}

pub fn coordinatorChoice(self: *State) Coordinator.Choice {
    var chosen: ?usize = null;
    var best: i32 = 0;
    var waiting = false;
    for (0..self.partyCount() + self.enemyCount()) |actor| {
        if (self.coordinatorActed(actor)) continue;
        if (self.coordinatorLocked(actor) or self.primaryEffectBusy(actor) or (actor < self.partyCount() and self.party_knockouts[actor].pending)) {
            waiting = true;
            continue;
        }
        const score = priority(self.stats(actor).speed, self.roll());
        if (chosen == null or (score > best and self.participates(actor))) {
            chosen = commandOwner(self, actor);
            best = score;
        }
    }
    if (self.spark_pending) {
        var pending = false;
        for (0..self.partyCount()) |actor| {
            if (self.coordinatorActed(actor)) continue;
            pending = true;
            if (self.coordinatorLocked(actor) or self.primaryEffectBusy(actor) or self.party_knockouts[actor].pending) continue;
            chosen = commandOwner(self, actor);
            break;
        }
        if (!pending) self.spark_pending = false;
    }
    return if (chosen) |actor| .{ .actor = actor } else if (waiting) .no_ready else .round_end;
}

pub fn retireDefeatedEnemyTurn(self: *State, actor: usize) void {
    if (self.pending_enemy_actor == actor) self.pending_enemy_actor = null;
    if (self.enemy_branch_selection) |selection| {
        if (selection.owner == actor) self.enemy_branch_selection = null;
    }
    self.acted[actor] = true;
    if (self.coordinator) |*clock| {
        if (clock.current_actor != actor) return;
        clock.completed = true;
        clock.stage = .select;
        clock.remaining = 0;
    }
}

pub fn advanceCoordinator(self: *State) void {
    const clock = &self.coordinator.?;
    for (self.unite_vm.wave_actions) |maybe| if (maybe) |playback| {
        if (playback.completed_at == self.camera_ticks) return;
    };
    for (self.unite_vm.commander_actions) |maybe| if (maybe) |playback| {
        if (playback.ordered_at != null and playback.ordered_at.? == self.camera_ticks) return;
    };
    switch (clock.stage) {
        .await_order, .round_ready, .round_setup => {},
        .select => {
            clock.remaining -%= 1;
            if (clock.remaining > 0) return;
            clock.cached = self.coordinatorChoice();
            switch (clock.cached.?) {
                .no_ready => {},
                .round_end => {
                    clock.remaining = 30;
                    clock.stage = .round_boundary;
                },
                .actor => |actor| {
                    if ((actor < self.partyCount()) != (clock.current_actor < self.partyCount())) clock.cross_side_pending = true;
                    clock.stage = .check;
                },
            }
        },
        .check => {
            const actor = clock.cached.?.actor;
            if (!self.participates(actor) or self.coordinatorLocked(actor) or self.primaryEffectBusy(actor)) {
                clock.stage = .select;
                return;
            }
            if (!clock.completed and clock.cross_side_pending) return;
            if (self.round_camera_choice) |choice| self.requestRoundCamera(choice, 20) catch {
                self.replay_unsupported = .coordinator_action;
                return;
            };
            clock.current_actor = actor;
            clock.completed = false;
            clock.cross_side_pending = false;
            clock.stage = .dispatch;
        },
        .dispatch => {
            const actor = clock.current_actor;
            const party_actor = actor < self.partyCount();
            const party_inactive = party_actor and battle.revival.committedPartyInactive(self.*, actor);
            const enemy_inactive = !party_actor and self.hp(actor) == 0;
            if (party_actor and !party_inactive and (!self.participates(actor) or self.party_knockouts[actor].revival != null)) return;
            const action_interrupted = party_actor and switch (self.actions[actor] orelse .defend) {
                .attack => self.unbalanced[actor] > 0,
                .spell, .rune_attack => self.actor_conditions[actor].rune_blocked or self.unbalanced[actor] > 0,
                else => false,
            };
            if (enemy_inactive) {
                self.retireDefeatedEnemyTurn(actor);
            } else if (party_inactive or self.actor_conditions[actor].sleep_turns > 0 or action_interrupted) {
                if (party_inactive) self.discardUnite(actor);
                self.acted[actor] = true;
                clock.completed = true;
                clock.stage = .select;
                clock.remaining = 0;
            } else if (dispatch.usesScriptedEnemyAction(self, actor)) {
                self.sourceEnemyDecision(actor);
                if (self.pending_enemy_actor != null or self.replay_unsupported != null or self.replay_exhausted) return;
            } else if (self.hasSourceRabbit(actor)) {
                self.rabbitDecision(actor);
                if (self.pending_enemy_actor != null or self.replay_unsupported != null or self.replay_exhausted) return;
            } else if (self.hasSourceCommander(actor)) {
                self.commanderDecision(actor);
                if (self.pending_enemy_actor != null or self.replay_unsupported != null or self.replay_exhausted) return;
            } else if (actor >= self.partyCount() and self.enemy(actor - self.partyCount()).action_policy == .front_projectile) {
                if (!self.frontProjectileDecision(actor)) return;
            } else if (actor >= self.partyCount() and self.enemy(actor - self.partyCount()).action_policy == .roc) {
                self.rocDecision(actor);
                if (self.active == null) return;
            } else if (!party_actor and self.enemy(actor - self.partyCount()).action_policy == .attack) {
                if (self.active != null) return;
                for (0..self.partyCount()) |target| if (self.coordinatorLocked(target)) return;
                if (self.chooseEnemyTarget(actor - self.partyCount())) |target| {
                    self.beginAttack(actor, target, .ordinary);
                    if (self.replay_exhausted or self.replay_unsupported != null) return;
                    self.active.?.started_at = clock.elapsed -| 1;
                } else {
                    clock.completed = true;
                }
                self.acted[actor] = true;
                clock.remaining = 0;
                clock.stage = .select;
            } else if (actor < self.partyCount() and self.actions[actor] != null and self.actions[actor].? == .defend) {
                self.acted[actor] = true;
                clock.completed = true;
                clock.remaining = 0;
                clock.stage = .select;
            } else if (actor < self.partyCount() and self.actions[actor] != null and self.actions[actor].? == .attack) {
                if (self.content.world_art == null and !self.sourceRounds()) {
                    // shortcut: serialize legacy party attacks until their source actor tracks are bound.
                    if (self.active != null) return;
                    const requested = self.actions[actor].?.attack;
                    const resolved: ?usize = if (self.canAttackTarget(actor, requested)) requested else self.firstAttackTarget(actor);
                    if (resolved) |target| if (self.coordinatorLocked(self.partyCount() + target)) return;
                    self.beginAttack(actor, self.partyCount() + requested, .ordinary);
                    if (self.replay_exhausted or self.replay_unsupported != null or self.active == null) return;
                    self.active.?.started_at = clock.elapsed -| 1;
                } else if (!startPartyStrike(self, actor, self.actions[actor].?.attack, null)) return;
                self.acted[actor] = true;
                clock.remaining = 0;
                clock.stage = .select;
            } else if (actor < self.partyCount() and self.actions[actor] != null and self.actions[actor].? == .item) {
                switch (startMedicine(self, actor)) {
                    .wait => return,
                    .rejected => {
                        self.acted[actor] = true;
                        clock.completed = true;
                        clock.stage = .select;
                        clock.remaining = 0;
                        return;
                    },
                    .started => {},
                }
                self.acted[actor] = true;
                clock.stage = .item_wait;
            } else if (actor < self.partyCount() and self.actions[actor] != null) {
                // Spell / physical-rune / Unite actions now reach
                // the same coordinator; each one keeps its own module rule
                // and the shared Draws stream.
                const action = self.actions[actor].?;
                const queued_spell = if (action == .spell) dispatch.queuedSpell(self, actor, action.spell) orelse {
                    self.replay_unsupported = .coordinator_action;
                    return;
                } else null;
                const needs_enemy = switch (action) {
                    .spell => !queued_spell.?.allies,
                    .rune_attack => |target| self.canPhysicalRune(actor) and target < self.enemyCount(),
                    .unite => |target| self.uniteBoundaryFor(actor) != null and target < self.enemyCount(),
                    else => false,
                };
                if (needs_enemy and self.firstLiving(false) == null) {
                    for (0..self.enemyCount()) |enemy| if (!self.enemyInactive(enemy)) return;
                    for (0..self.partyCount() + self.enemyCount()) |index| if (self.coordinatorLocked(index)) return;
                    if (action == .unite) {
                        self.discardUnite(actor);
                    }
                    self.acted[actor] = true;
                    clock.completed = true;
                    clock.stage = .select;
                    clock.remaining = 0;
                    return;
                }
                switch (action) {
                    .spell => |cast| switch (dispatch.startSpellAction(self, actor, cast)) {
                        .started => {},
                        .wait => return,
                        .rejected => {
                            clock.stage = .select;
                            clock.remaining = 0;
                            return;
                        },
                    },
                    .rune_attack => |target| {
                        if (!self.canPhysicalRune(actor) or target >= self.enemyCount()) {
                            self.replay_unsupported = .coordinator_action;
                            return;
                        }
                        switch (dispatch.startRuneAttack(self, actor, target)) {
                            .started => {},
                            .wait => return,
                            .rejected => {
                                clock.stage = .select;
                                clock.remaining = 0;
                                return;
                            },
                        }
                    },
                    .unite => |target| {
                        if (self.uniteBoundaryFor(actor) == null or target >= self.enemyCount()) {
                            self.replay_unsupported = .coordinator_action;
                            return;
                        }
                        switch (self.startUniteAction(actor, target)) {
                            .started => {},
                            .wait => return,
                            .rejected => {
                                self.discardUnite(actor);
                                self.acted[actor] = true;
                                clock.completed = true;
                                clock.stage = .select;
                                clock.remaining = 0;
                                return;
                            },
                        }
                    },
                    .assist => |owner| {
                        if (owner >= self.partyCount() or !self.acted[owner]) {
                            self.replay_unsupported = .coordinator_action;
                            return;
                        }
                        self.acted[actor] = true;
                        clock.completed = true;
                        clock.stage = .select;
                        clock.remaining = 0;
                        return;
                    },
                    else => {
                        self.replay_unsupported = .coordinator_action;
                        return;
                    },
                }
                // Unite selection installs its initializer for the next primary pass.
                self.active.?.started_at = if (self.active.?.kind == .unite) clock.elapsed else clock.elapsed -| 1;
                self.acted[actor] = true;
                clock.remaining = 0;
                clock.completed = !self.sourcePhysicalRuneOwner(actor);
                clock.stage = .select;
            } else {
                self.replay_unsupported = .coordinator_action;
                return;
            }
            clock.dispatch_count += 1;
            clock.last_dispatched = actor;
        },
        .item_wait => {
            if (self.medicine_action.?.ticks + 1 == self.medicine_action.?.timing.target_start) {
                clock.completed = true;
                clock.stage = .select;
            }
        },
        .victory_wait => {
            clock.remaining -%= 1;
            if (clock.remaining < 0) finishBattle(self, .victory);
        },
        .round_boundary => {
            clock.remaining = @max(0, clock.remaining -| 1);
            if (clock.remaining > 0) return;
            for (0..self.partyCount() + self.enemyCount()) |actor| if (self.coordinatorLocked(actor)) return;
            clock.stage = .round_ready;
        },
    }
}
pub fn beginMedicine(self: *State, actor: usize) bool {
    return startMedicine(self, actor) == .started;
}

const ItemStart = enum { started, wait, rejected };

fn startMedicine(self: *State, actor: usize) ItemStart {
    const selected = self.actions[actor].?.item;
    var timing = for (self.content.medicine_timings) |entry| {
        if (std.mem.eql(u8, entry.id, self.progress.party.at(actor).id)) break entry;
    } else {
        self.replay_unsupported = .coordinator_action;
        return .wait;
    };
    const definition = self.rules.consumable(selected.id) orelse {
        self.replay_unsupported = .coordinator_action;
        return .wait;
    };
    if (definition.battle) |effect| {
        timing.pending_tick = timing.target_start + effect.pending_delay;
        timing.impact_tick = timing.target_start + effect.impact_delay;
        timing.target_release = timing.target_start + effect.release_delay;
    } else if (selected.id != .medicine) {
        self.replay_unsupported = .coordinator_action;
        return .wait;
    }
    if (selected.target >= self.partyCount() or self.actor_conditions[actor].sleep_turns > 0) {
        self.replay_unsupported = .coordinator_action;
        return .wait;
    }
    // shortcut: retain one item effect until both tracks finish; qualify interrupted overlaps before relaxing this.
    if (self.medicine_action) |item| if (!item.owner_released or !item.target_released) return .wait;
    for (0..self.partyCount() + self.enemyCount()) |index| if (self.coordinatorLocked(index)) return .wait;
    const inventory = &self.progress.party.at(actor).inventory;
    if (selected.slot >= inventory.count() or inventory.slots[selected.slot].?.id != selected.id or (definition.uses != 0 and inventory.slots[selected.slot].?.uses == 0)) {
        self.replay_unsupported = .coordinator_action;
        return .wait;
    }
    if (!definition.partyWide() and !self.participates(selected.target)) {
        if (!self.departed[selected.target] and (self.party_knockouts[selected.target].pending or !self.partyInactive(selected.target))) return .wait;
        return .rejected;
    }
    if (definition.uses != 0) inventory.spendUse(selected.slot, selected.id) catch unreachable;
    var targets: u8 = 0;
    if (definition.partyWide()) for (0..self.partyCount()) |index| if (self.participates(index)) {
        targets |= @as(u8, 1) << @intCast(index);
    };
    self.medicine_action = .{ .id = selected.id, .timing = timing, .actor = actor, .target = if (definition.partyWide()) actor else selected.target, .targets = targets, .started_at = self.presentation_tick };
    return .started;
}
pub fn advanceMedicine(self: *State) void {
    const item = if (self.medicine_action) |*value| value else return;
    const timing = item.timing;
    if (item.owner_released and item.target_released) return;
    item.ticks += 1;
    const definition = self.rules.consumable(item.id).?;
    if (item.ticks == timing.target_start) {
        for (0..self.partyCount()) |index| if (item.affects(index)) {
            item.particle_origins[index] = @import("battle_layout.zig").worldPosition(self, index);
            item.particle_sprites[index] = @import("battle_layout.zig").actorLayout(self.*, index).sprite;
            if (self.content.world_art) |art| {
                const sample = battle.world_art.actorSample(art, self, index).sample;
                item.particle_poses[index] = sample.pose;
            }
        };
    }
    if (item.ticks == timing.target_start) if (definition.cure) |cure| {
        const target = self.progress.party.at(item.target).*;
        if ((cure == .poison and target.status != .poisoned) or (cure == .balloon and target.balloons == 0)) {
            item.target_released = true;
            item.target_interrupted = true;
        } else {
            item.detached_status = if (cure == .poison) 0 else @intCast(target.balloons);
        }
    };
    if (item.ticks == timing.pending_tick) {
        for (0..self.partyCount()) |index| if (item.affects(index) and !item.interrupted(index) and self.participates(index)) {
            var pending = self.progress.party.at(index).*;
            item.amounts[index] = definition.applyTo(&pending, self.actor_conditions[index].protection_rounds > 0);
        };
        item.amount = item.amounts[item.target];
    }
    if (item.ticks == timing.impact_tick) {
        for (item.amounts[0..self.partyCount()], 0..) |*amount, index| {
            if (!item.affects(index) or item.interrupted(index) or !self.participates(index)) {
                amount.* = 0;
                continue;
            }
            const target = self.progress.party.at(index);
            const before = target.*;
            target.hp = @min(target.max_hp, target.hp +| amount.*);
            amount.* = target.hp -| before.hp;
            _ = definition.applyTo(target, true);
            self.noteItemImpact(index, before);
        }
        item.amount = item.amounts[item.target];
    }
    if (item.ticks == timing.target_release) item.target_released = true;
    if (item.ticks == (if (item.actor == item.target and !item.interrupted(item.actor)) timing.target_release else timing.owner_release)) item.owner_released = true;
}
pub fn partyAttackTiming(self: *const State, actor: usize) ?PartyAttackTiming {
    for (self.content.party_attacks) |timing| if (std.mem.eql(u8, timing.id, self.progress.party.at(actor).id)) return timing;
    return null;
}
fn startPartyStrike(self: *State, actor: usize, requested: usize, origin: ?battle.Position) bool {
    // shortcut: only exported owner/target tracks; counters and other formations remain gated.
    if (requested < self.enemyCount() and self.enemy_hp[requested] == 0) {
        if (!self.enemyInactive(requested)) return false;
        // Source dispatch rescans valid survivors without repeating command-menu reach filtering.
        const replacement = (if (self.sharedPartyMelee()) if (self.firstLiving(false)) |target| target - self.partyCount() else null else self.firstAttackTarget(actor)) orelse {
            if (self.firstLiving(false) != null) {
                self.replay_unsupported = .coordinator_action;
                return false;
            }
            self.coordinator.?.completed = true;
            return true;
        };
        self.actions[actor] = .{ .attack = replacement };
        return false;
    }
    if (self.usesProfileAttack(requested)) {
        const target = self.partyCount() + requested;
        if (self.active != null or self.coordinatorLocked(target)) return false;
        self.beginAttack(actor, target, .ordinary);
        if (self.replay_exhausted or self.replay_unsupported != null) return false;
        self.active.?.started_at = self.coordinator.?.elapsed -| 1;
        self.active.?.motion_origin = origin;
        return true;
    }
    if (origin == null) if (self.unite_actors) |bundle| if (bundle.counterPacket()) |packet| {
        if (packet.rangedAttacker(self.progress.party.at(actor).id) != null) return startRangedStrike(self, actor, requested);
        if (packet.partyAttacker(self.progress.party.at(actor).id, .melee_hit) != null) return startMeleeStrike(self, actor, requested);
    };
    const tracks = if (self.content.world_art) |art| art.attackTracks(self.progress.party.at(actor).id, requested) else null;
    if ((!std.mem.eql(u8, self.progress.party.at(actor).id, "hero") and tracks == null) or self.party_strikes[actor] != null or self.partyAttackTiming(actor) == null or requested >= self.enemyCount() or self.actor_conditions[actor].sleep_turns > 0 or self.unbalanced[actor] > 0) {
        self.replay_unsupported = .coordinator_action;
        return false;
    }
    const resolved = if (self.enemy_hp[requested] > 0) requested else self.firstAttackTarget(actor) orelse {
        self.replay_unsupported = .coordinator_action;
        return false;
    };
    if (!self.canAttackTarget(actor, resolved)) {
        self.replay_unsupported = .coordinator_action;
        return false;
    }
    const target = self.partyCount() + resolved;
    if (origin == null and self.coordinatorLocked(target)) return false;
    if ((!std.mem.eql(u8, self.enemy(resolved).id, "flying_squirrel") and !std.mem.eql(u8, self.enemy(resolved).id, "roc") and !std.mem.eql(u8, self.enemy(resolved).id, "kobold_type_2")) or self.enemy(resolved).knockout_ticks == null) {
        self.replay_unsupported = .coordinator_action;
        return false;
    }
    if (self.hasRune(actor, "double-beat")) {
        if (self.partyAttackTiming(actor).?.motion == null) {
            self.replay_unsupported = .coordinator_action;
            return false;
        }
        self.double_beat_pending[actor] = !self.double_beat_pending[actor];
    }
    if (self.hasRune(actor, "spark")) self.spark_pending = true;
    const hit = hitsWithAccuracyPenalty(self.stats(actor).skill, self.stats(target).skill, self.roll(), self.actor_conditions[actor].accuracy_reduced);
    const missed = !hit and self.enemy(resolved).dodges_attacks;
    if (missed) {
        const art = self.content.world_art;
        const dodge = self.enemy(resolved).dodge;
        if (dodge == null or self.partyAttackTiming(actor).?.dodge_start_tick == null or art == null or art.?.actors[target].animations.len <= dodge.?.animation or art.?.actors[target].animations[dodge.?.animation].len == 0) {
            self.replay_unsupported = .coordinator_action;
            return false;
        }
    }
    const selected_critical = !missed and critical(self.stats(actor).skill, self.stats(actor).luck, self.hasRune(actor, "killer"), self.roll());
    if (selected_critical and (self.enemy(resolved).action_policy == .roc or self.enemy(resolved).action_policy == .front_projectile) and !criticalReady(self, actor, target)) {
        self.replay_unsupported = .coordinator_action;
        return false;
    }
    if (selected_critical) if (self.partyAttackTiming(actor).?.critical_camera) |request| {
        if (self.actor_camera == null) self.actor_camera = @import("battle_camera").ActorController.init(battle.layout.cameraForTransition(self)) catch {
            self.replay_unsupported = .coordinator_action;
            return false;
        };
        var destination = request.target;
        const anchor = battle.layout.worldPosition(self, target);
        destination.focus[0] = @intFromFloat(@round(anchor.x * 4096));
        destination.focus[1] = @intFromFloat(@round(anchor.y * 4096));
        self.actor_camera.?.requestQ12(destination, request.updates) catch {
            self.replay_unsupported = .coordinator_action;
            return false;
        };
    };
    if (self.medicine_action) |*item| item.interrupt(actor);
    self.party_strikes[actor] = .{ .actor = actor, .target = target, .critical = selected_critical, .missed = missed, .origin = origin };
    // Critical camera ownership uses the same completion gate as a side change.
    if (selected_critical) self.coordinator.?.cross_side_pending = true;
    return true;
}
pub fn startMeleeStrike(self: *State, actor: usize, requested: usize) bool {
    return startActorStrike(self, actor, requested, true);
}
pub fn startRangedStrike(self: *State, actor: usize, requested: usize) bool {
    return startActorStrike(self, actor, requested, false);
}
fn startActorStrike(self: *State, actor: usize, requested: usize, melee: bool) bool {
    if (!self.canStartAttack(actor) or requested >= self.enemyCount() or self.enemy_hp[requested] == 0 or (!self.sharedPartyMelee() and !self.canAttackTarget(actor, requested))) {
        self.replay_unsupported = .coordinator_action;
        return false;
    }
    const target = self.partyCount() + requested;
    if (self.coordinatorLocked(target) or self.unite_vm.ownsActor(actor) or self.unite_vm.ownsActor(target)) return false;
    if (self.hasRune(actor, "double-beat")) self.double_beat_pending[actor] = !self.double_beat_pending[actor];
    if (self.hasRune(actor, "spark")) self.spark_pending = true;
    const hit = hitsWithAccuracyPenalty(self.stats(actor).skill, self.stats(target).skill, self.roll(), self.actor_conditions[actor].accuracy_reduced);
    if (melee and !hit) {
        const parry = self.parryAvailable(actor, target) catch {
            self.replay_unsupported = .coordinator_action;
            return false;
        };
        if (self.replay_exhausted) return false;
        if (parry) {
            self.beginParry(actor, target) catch {
                self.replay_unsupported = .coordinator_action;
                return false;
            };
            return true;
        }
    }
    const missed = !hit and self.enemy(requested).dodges_attacks;
    const selected_critical = !missed and critical(self.stats(actor).skill, self.stats(actor).luck, self.hasRune(actor, "killer"), self.roll());
    if (self.replay_exhausted) return false;
    const started = if (melee) self.beginPartyMelee(actor, target, !missed, selected_critical) else self.beginRanged(actor, target, !missed, selected_critical);
    started catch {
        self.replay_unsupported = .coordinator_action;
        return false;
    };
    const bindings = if (melee) self.unite_actors.?.counterPacket().?.party_melee.? else self.unite_actors.?.counterPacket().?.ranged.?;
    if (selected_critical) if (bindings.critical_camera) |request| {
        if (self.actor_camera == null) self.actor_camera = @import("battle_camera").ActorController.init(battle.layout.cameraForTransition(self)) catch {
            self.replay_unsupported = .coordinator_action;
            return false;
        };
        var destination = request.target;
        const anchor = battle.layout.worldPosition(self, target);
        destination.focus[0] = @intFromFloat(@round(anchor.x * 4096));
        destination.focus[1] = @intFromFloat(@round(anchor.y * 4096));
        self.actor_camera.?.requestQ12(destination, request.updates) catch {
            self.replay_unsupported = .coordinator_action;
            return false;
        };
    };
    if (selected_critical) if (self.coordinator) |*clock| {
        clock.cross_side_pending = true;
    };
    if (self.medicine_action) |*item| item.interrupt(actor);
    return true;
}
fn criticalReady(self: *const State, actor: usize, target: usize) bool {
    const timing = self.partyAttackTiming(actor).?;
    const impacts = timing.impacts orelse return false;
    if (timing.critical_camera == null) return false;
    const packet = self.spell_scenes orelse return false;
    const art = self.content.world_art orelse return false;
    if (target >= art.actors.len or art.actors[target].impact_offsets == null) return false;
    var white = false;
    for (packet.physical_white_poses) |pose| if (std.mem.eql(u8, pose.id, self.enemy(target - self.partyCount()).id)) {
        white = true;
    };
    if (!white) return false;
    for (impacts.critical) |spawn| {
        var found = false;
        for (packet.unite_impacts) |clip| if (clip.id == spawn.animation) {
            found = true;
        };
        if (!found) return false;
    }
    return true;
}
fn captureStrikeImpacts(self: *State, strike: *battle.PartyStrike) void {
    // shortcut: shared auxiliary exhaustion still needs actor-host allocation and script stalls.
    if (strike.missed) return;
    const spec = self.partyAttackTiming(strike.actor).?.impacts orelse return;
    const art = self.content.world_art orelse return;
    const offsets = art.actors[strike.target].impact_offsets orelse return;
    const spawns = if (strike.critical) spec.critical else spec.ordinary;
    const impact = self.partyAttackTiming(strike.actor).?.impact_tick;
    for (spawns, 0..) |spawn, i| {
        if (strike.ticks != impact + spawn.at) continue;
        const sample = battle.world_art.actorSample(art, self, strike.target).sample;
        // Opcode24 copies position before this update's movement integration.
        strike.ticks -= 1;
        const position = battle.world_art.actorSample(art, self, strike.target).sample.position;
        strike.ticks += 1;
        var point: [3]i32 = undefined;
        inline for (.{ "x", "y", "z" }, 0..) |axis, k| point[k] = @as(i32, @intFromFloat(@round(@field(position, axis) * 4096))) + @as(i32, spawn.offset[k]) * 4096;
        strike.impact_births[i] = .{ .position_q12 = point, .center = offsets[sample.pose] };
    }
}
pub fn advancePartyStrike(self: *State) void {
    for (0..self.partyCount()) |member| self.advanceUniteReturn(member);
    // Advance old reactions before owners so a newly retained tail starts next tick.
    for ([_][]?battle.PartyStrike{ self.party_strikes[6..], self.party_strikes[0..6] }) |slots| for (slots) |*slot| {
        const strike = if (slot.*) |*value| value else continue;
        const timing = self.partyAttackTiming(strike.actor).?;
        strike.ticks += 1;
        if (strike.missed and strike.ticks == timing.dodge_start_tick.?) {
            strike.ticks -= 1;
            const origin = battle.world_art.actorSample(self.content.world_art.?, self, strike.target).sample.position;
            strike.ticks += 1;
            strike.dodge_origin = origin;
        }
        if (!strike.missed and strike.ticks == timing.impact_tick) {
            self.dodge_idle_at[strike.target - self.partyCount()] = null;
            const damage = self.resolvePhysicalDamage(strike.actor, strike.target, self.roll(), false) * @as(u32, if (strike.critical) 3 else 1);
            strike.amount = if (self.actor_conditions[strike.target].protection_rounds > 0) 0 else damage;
            self.enemy_hp[strike.target - self.partyCount()] -|= @intCast(@min(strike.amount, 65535));
        }
        captureStrikeImpacts(self, strike);
        const hurt_end = if (strike.missed) self.enemy(strike.target - self.partyCount()).dodge.?.releaseTick(timing) else timing.impact_tick + timing.target_release_delay;
        if (strike.ticks == hurt_end) {
            strike.target_down = self.hp(strike.target) == 0;
            strike.target_released = !strike.target_down;
            if (strike.missed) self.dodge_idle_at[strike.target - self.partyCount()] = self.presentation_tick - (strike.ticks - timing.dodge_start_tick.? - self.enemy(strike.target - self.partyCount()).dodge.?.back.ticks);
            if (strike.target_released and self.enemy(strike.target - self.partyCount()).action_policy == .roc) {
                self.roc_idle_at = if (strike.missed) self.dodge_idle_at[strike.target - self.partyCount()].? else self.presentation_tick;
                self.roc_home_restored = !strike.missed;
            }
        }
        if (strike.target_down and strike.ticks == hurt_end + self.enemy(strike.target - self.partyCount()).knockout_ticks.? - 1) strike.target_released = true;
        // Settle any same-tick target reaction before handing it off to a tail.
        if (strike.ticks == timing.return_tick) {
            if (!strike.owner_released) if (self.nextDoubleBeatTarget(strike.actor, strike.target - self.partyCount())) |next| {
                const previous = strike.*;
                const origin = battle.layout.worldPosition(self, strike.actor);
                self.party_strikes[6 + strike.actor] = previous;
                self.party_strikes[6 + strike.actor].?.owner_released = true;
                slot.* = null;
                if (!startPartyStrike(self, previous.actor, next, origin)) return;
                continue;
            };
            strike.returning = true;
            if (self.coordinator.?.current_actor == strike.actor) self.coordinator.?.completed = true;
        }
        if (strike.ticks == timing.release_tick and !strike.owner_released) {
            strike.owner_released = true;
            self.front_hurt_at[strike.actor] = null;
            if (strike.actor == 0) self.hero_reaction_offset = false;
        }
        if (strike.owner_released and strike.target_released) slot.* = null;
    };
}
