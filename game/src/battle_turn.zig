//! Battle turn resolver: round boundary, action presentation, impacts and end state.
const std = @import("std");
const field = @import("field");
const systems = @import("battle_rules");
const State = @import("battle.zig").State;

pub fn resolveTick(state: *State) void {
    defer state.advanceRevivals();
    var camera_with_actors = false;
    var camera_advanced = false;
    defer if (!camera_with_actors and !camera_advanced) state.advanceActorCamera();
    state.advancePhysicalRunes();
    if (state.replay_exhausted or state.replay_unsupported != null) return;
    if (state.round_menu_pending) {
        if (state.hasPendingRevival()) return;
        state.round_menu_pending = false;
        state.promoteRearMembers();
        if (state.firstLiving(true) == null) state.phase = .defeat else state.openAfterRound();
        return;
    }
    var returns_advanced = false;
    defer if (!returns_advanced) state.advanceUniteReturns();
    camera_with_actors = true;
    defer {
        state.advancePhysicalRunes();
        if (!camera_advanced) state.advanceActorCamera();
        state.advanceUniteActors();
    }
    if (state.round_start_pending) {
        const timing = state.content.round_start.?;
        const choice: u8 = @intCast(state.roll() % timing.camera_choices);
        state.round_camera_choice = choice;
        state.requestRoundCamera(choice, timing.selection_delay) catch {
            state.replay_unsupported = .coordinator_action;
            return;
        };
        state.round_start_pending = false;
        state.acted = @splat(false);
        for (0..state.partyCount() + state.enemyCount()) |actor| state.acted[actor] = !state.participates(actor) or state.actor_conditions[actor].sleep_turns > 0;
        state.action_ticks = 0;
        state.coordinator = .{ .stage = .select, .current_actor = state.last_round_actor, .cached = .round_end, .completed = true, .remaining = @intCast(timing.selection_delay), .elapsed = 0 };
        return;
    }
    if (state.coordinator) |clock| if (clock.stage == .round_setup) {
        // The coordinator round boundary now retires protection,
        // recovery (retain then clear), sleep and poison before the next
        // command menu, matching the ordinary path's boundary.
        if (state.integration != null or state.sharedPartyMelee()) state.applyRoundBoundaryStatuses() else if (!state.hasPendingRevival()) state.promoteRearMembers();
        state.last_round_actor = clock.current_actor;
        state.round += 1;
        state.medicine_action = null;
        state.actions = @splat(null);
        state.party_strikes = @splat(null);
        state.coordinator = null;
        state.active = null;
        state.pending_enemy_actor = null;
        state.action_ticks = clock.elapsed + 1;
        if (state.hasPendingRevival()) state.round_menu_pending = true else state.openAfterRound();
        return;
    };
    if (state.pending_enemy_actor) |actor| {
        if (state.coordinator != null) {
            state.coordinator.?.elapsed += 1;
            state.action_ticks = state.coordinator.?.elapsed;
        }
        if (state.hp(actor) == 0) {
            state.retireDefeatedEnemyTurn(actor);
        } else switch (state.enemy(actor - state.partyCount()).action_policy) {
            .commander, .source_commander => state.commanderDecision(actor),
            .roc => state.rocDecision(actor),
            .front_projectile => _ = state.frontProjectileDecision(actor),
            .source_melee, .source_magic, .source_projectile, .source_ninja, .source_dagon, .source_whip_wolf, .source_holly_fairy, .source_sorcerer, .source_siren, .source_earth_golem, .source_creeper, .source_shadow_man, .source_mirage_f, .source_mirage_h, .ant_double_strike => state.sourceEnemyDecision(actor),
            else => state.rabbitDecision(actor),
        }
        state.advanceMedicine();
        state.advancePartyStrike();
        state.advanceFrontProjectiles();
        if (state.coordinator != null) state.issueSpellCameraRequest(state.effectTicks());
        return;
    }
    if (state.coordinator) |clock| {
        if (clock.stage == .round_ready and state.active == null) {
            if (state.hasPendingRevival()) return;
            if (state.firstLiving(false) == null) {
                if (state.hasUniteReturns()) return;
                state.coordinator.?.stage = .victory_wait;
                state.coordinator.?.remaining = 30;
                state.coordinator.?.elapsed += 1;
                state.action_ticks = state.coordinator.?.elapsed;
            } else if (state.firstLiving(true) == null) {
                state.action_ticks = clock.elapsed + 1;
                state.phase = .defeat;
                state.coordinator = null;
            } else if (state.sourceRounds()) {
                // Settled source tracks are still required; integrated statuses use the shared boundary.
                if (state.round == std.math.maxInt(u32) or (state.content.world_art != null and state.content.world_art.?.c_tracks == null and state.roc_idle_at == null) or state.content.round_start == null or state.partyTargetDown()) {
                    state.replay_unsupported = .coordinator_action;
                    return;
                }
                const c_knockouts = (state.content.world_art != null and state.content.world_art.?.c_tracks != null) or
                    (state.content.world_art == null and state.content.presentation_ready and state.sourceRounds());
                const statuses_ready = state.integration != null or state.sharedPartyMelee();
                for (state.progress.party, 0..) |member, index| {
                    const expected_status: field.game_state.Status = if (member.hp == 0) .unconscious else .healthy;
                    const supported_status = member.status == expected_status or (statuses_ready and member.hp > 0 and member.status == .poisoned);
                    if ((member.hp == 0 and !c_knockouts) or !supported_status or (!statuses_ready and (member.balloons != 0 or state.actor_conditions[index].sleep_turns != 0 or state.actor_conditions[index].protection_rounds != 0 or state.unbalanced[index] != 0 or state.actor_conditions[index].accuracy_reduced or state.actor_conditions[index].rune_blocked or state.hasRune(index, "sunbeam")))) {
                        state.replay_unsupported = .coordinator_action;
                        return;
                    }
                }
                state.coordinator.?.stage = .round_setup;
                state.coordinator.?.elapsed += 1;
                state.action_ticks = state.coordinator.?.elapsed;
            } else {
                state.coordinator = null;
                state.nextAction();
            }
            return;
        }
        state.coordinator.?.elapsed += 1;
        state.action_ticks = state.coordinator.?.elapsed;
        state.advanceCoordinator();
        if (state.replay_exhausted or state.replay_unsupported != null or state.coordinator == null) return;
        state.advanceMedicine();
        state.advancePartyStrike();
        returns_advanced = true;
        state.advanceFrontProjectiles();
        if (state.replay_exhausted or state.replay_unsupported != null or state.active == null) return;
    } else {
        if (state.active == null) {
            state.nextAction();
            return;
        }
        state.action_ticks += 1;
    }
    state.advancePhysicalRunes();
    const effect_tick = state.effectTicks();
    state.issueSpellCameraRequest(effect_tick);
    if (state.replay_unsupported != null) return;
    state.advanceActorCamera();
    camera_advanced = true;
    if (state.active.?.counter_attack) return;
    if (state.active.?.kind == .enemy_magic or state.active.?.kind == .enemy_command) return;
    if (state.active.?.rune_attack and state.sourcePhysicalRuneOwner(state.active.?.actor)) return;
    state.advancePresentation(effect_tick);
    state.issueUniteCameraRequests(effect_tick);
    if (state.replay_unsupported != null) return;
    if (state.active.?.damage_at_impact and !state.active.?.projectile and effect_tick == state.enemy(state.active.?.actor - state.partyCount()).ordinary_timing.?.return_tick) state.active.?.returning = true;
    if (state.active.?.damage_at_impact and state.enemy(state.active.?.actor - state.partyCount()).action_policy == .roc) {
        const effect = &state.active.?;
        const timing = state.enemy(effect.actor - state.partyCount()).ordinary_timing.?;
        if (effect_tick == timing.return_tick and state.coordinator.?.current_actor == effect.actor) state.coordinator.?.completed = true;
        if (effect.protector == null and effect_tick == timing.impact_tick + timing.target_release_delay.?) {
            effect.target_released = true;
            if (state.hp(effect.target) == 0) {
                effect.target_down = state.commitPartyKnockout(effect.target);
            }
        }
    }
    if (state.active.?.projectile and effect_tick == state.enemy(state.active.?.actor - state.partyCount()).projectile.?.release_tick) state.active.?.projectile_alive = false;
    if (state.active.?.kind == .group_order) state.resolveCommanderOrder();
    if (state.active.?.kind == .status_attack) {
        const timing = state.enemy(state.active.?.actor - state.partyCount()).commander.?;
        if (effect_tick == timing.auxiliary_spawn_tick) state.active.?.auxiliary_alive = true;
        if (effect_tick == timing.auxiliary_release_tick) state.active.?.auxiliary_alive = false;
        if (effect_tick == timing.reaction_tick) state.active.?.target_reacting = true;
        if (effect_tick == timing.owner_release_tick) state.active.?.owner_released = true;
    }
    if (state.active.?.protector != null) {
        if (effect_tick == state.protectorReleaseTick(state.active.?)) {
            state.active.?.protector_released = true;
            const guard = state.active.?.protector.?;
            if (state.hp(guard) == 0) {
                state.active.?.protector_down = state.commitPartyKnockout(guard);
            }
        }
        if (effect_tick == state.wardReturnTick(state.active.?) and state.revivalAllowsWard(state.active.?.protector.?)) state.active.?.ward_returning = true;
        if (effect_tick == state.wardReturnTick(state.active.?) + state.content.protection.?.ward_return_duration) state.active.?.ward_released = true;
    }
    if (state.hasSpellScene()) {
        state.advanceSpellScene(effect_tick);
        if (state.replay_exhausted or state.replay_unsupported != null) return;
    }
    state.advanceUniteTransition();
    state.advanceUniteScene();
    if (state.replay_unsupported != null) return;
    const assist_after = state.uniteAssistAfterDamage();
    if (!assist_after) state.resolveUniteAssistReactions();
    if (state.martial_queue != null or state.hasUniteSequence() or state.hasLiveUniteActors()) {
        // shortcut: actor-local source clocks; full choreography still needs frame-driver alignment.
        state.resolveUniteImpact();
        if (state.replay_exhausted or state.replay_unsupported != null or state.active.?.kind == .unavailable) return;
    }
    if (assist_after) state.resolveUniteAssistReactions();
    if (effect_tick == state.impactTick() and state.martial_queue == null and !state.hasUniteSequence() and !state.hasLiveUniteActors()) {
        const effect = &state.active.?;
        switch (effect.kind) {
            .attack, .unite => {
                if (effect.unite_boundary) {
                    // One physical result per participant in record
                    // order, combined by the record multiplier and applied
                    // once; any failure restores the whole boundary.
                    state.resolveUniteImpact();
                    if (state.active != null and state.active.?.kind == .unavailable) return;
                } else {
                    const damage_target = effect.protector orelse effect.target;
                    if (effect.damage_at_impact) {
                        const defending = state.actions[damage_target] != null and state.actions[damage_target].? == .defend;
                        effect.amount = state.resolvePhysicalDamage(effect.actor, damage_target, state.roll(), defending);
                    }
                    if (effect.rune_attack and (!state.participates(effect.actor) or state.actor_conditions[effect.actor].sleep_turns > 0 or !state.canPhysicalRune(effect.actor))) {
                        effect.kind = .unavailable;
                        return;
                    }
                    if (effect.kind == .unite and (effect.partner == null or !state.participates(effect.partner.?) or state.actor_conditions[effect.partner.?].sleep_turns > 0 or !state.participates(effect.actor) or state.actor_conditions[effect.actor].sleep_turns > 0)) {
                        effect.kind = .unavailable;
                        return;
                    }
                    if (effect.damage_at_impact and effect.protector == null and effect.target == 0 and state.enemy(effect.actor - state.partyCount()).action_policy == .roc) state.hero_reaction_offset = true;
                    if (state.actor_conditions[damage_target].protection_rounds > 0) effect.amount = 0;
                    if (damage_target < state.partyCount()) {
                        const target = &state.progress.party[damage_target];
                        target.hp = @intCast(@as(u32, target.hp) -| effect.amount);
                        state.markPartyKnockout(damage_target);
                    } else state.enemy_hp[damage_target - state.partyCount()] = @intCast(@as(u32, state.enemy_hp[damage_target - state.partyCount()]) -| effect.amount);
                }
            },
            .item => {
                // shortcut: legacy demo clock; source item clocks use the separate coordinator action above.
                const target = &state.progress.party[effect.target];
                const selected = state.actions[effect.actor].?.item;
                const inventory = &state.progress.party[effect.actor].inventory;
                const definition = state.rules.consumable(selected.id);
                if (!state.participates(effect.target)) {
                    effect.kind = .unavailable;
                } else if (definition == null) {
                    effect.kind = .unavailable;
                } else {
                    if (definition.?.uses != 0) inventory.spendUse(selected.slot, selected.id) catch {
                        effect.kind = .unavailable;
                        return;
                    };
                    if (definition.?.partyWide()) {
                        for (0..state.partyCount()) |index| if (state.participates(index)) {
                            effect.affected |= @as(u16, 1) << @intCast(index);
                            const member = &state.progress.party[index];
                            const before = member.*;
                            effect.amounts[index] = definition.?.applyTo(member, state.actor_conditions[index].protection_rounds > 0);
                            state.noteItemImpact(index, before);
                        };
                        effect.amount = effect.amounts[effect.target];
                    } else {
                        const before = target.*;
                        effect.amount = definition.?.applyTo(target, state.actor_conditions[effect.target].protection_rounds > 0);
                        state.noteItemImpact(effect.target, before);
                    }
                }
            },
            .cast => state.applySpell(effect),
            .status_attack => {
                const percent = state.enemy(effect.actor - state.partyCount()).commander.?.status_percent;
                if (!state.statusImmune(effect.target) and systems.statusPercent(state.roll()) < percent) {
                    if (state.inflictStatus(effect.target, .sleep)) state.acted[effect.target] = true;
                }
            },
            .escape => {
                if (state.runSucceeds(state.roll())) {
                    state.phase = .escaped;
                    return;
                }
                effect.kind = .escape_failed;
            },
            else => {},
        }
    }
    state.advanceActiveUniteReturns();
    if (state.replay_unsupported != null) return;
    if (state.uniteTargetReleaseTick()) |release| {
        // The configured reaction releases living targets; the knockout tail owns its own release.
        if (effect_tick == release and state.hp(state.active.?.target) > 0) state.active.?.target_released = true;
    }
    if (effect_tick >= state.actionDuration()) {
        state.holdSpellCamera();
        if (state.active.?.kind == .unite and state.active.?.unite_boundary) {
            if (state.uniteHandoffTick() != null) state.handoffUnite() else state.finishUnite();
        } else if (state.active.?.kind == .unite) {
            const effect = state.active.?;
            const recovery = state.uniteDefinition(effect.actor).?.recovery_rounds;
            if (recovery > 0) {
                if (!state.statusImmune(effect.actor)) state.unbalanced[effect.actor] = recovery + 1;
                if (!state.statusImmune(effect.partner.?)) state.unbalanced[effect.partner.?] = recovery + 1;
            }
        }
        if (state.active.?.kind == .attack and state.active.?.rune_attack and state.active.?.recovery_rounds > 0 and !state.statusImmune(state.active.?.actor)) {
            if (state.integration != null) _ = state.roll();
            state.unbalanced[state.active.?.actor] = state.active.?.recovery_rounds + 1;
        }
        const previous = state.active.?;
        if (state.followupTarget(previous)) |target| {
            state.beginAttack(previous.actor, target, .{ .followup = previous.target });
            if (state.coordinator) |clock| {
                if (state.active) |*effect| effect.started_at = clock.elapsed;
                state.action_ticks = clock.elapsed;
            } else state.action_ticks = 0;
            return;
        }
        if (previous.damage_at_impact and state.enemy(previous.actor - state.partyCount()).action_policy == .roc) state.roc_idle_at = state.presentation_tick;
        state.active = null;
        if (state.coordinator) |*clock| {
            if (clock.current_actor == previous.actor) clock.completed = true;
            return;
        }
        if (state.firstLiving(true) == null and !state.hasPendingRevival()) {
            state.phase = .defeat;
            return;
        }
        if (state.firstLiving(false) == null and !state.hasUniteReturns() and !state.hasPendingRevival()) {
            state.commitRewards();
            state.phase = .victory;
        }
    }
}
