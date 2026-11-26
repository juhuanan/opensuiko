const std = @import("std");
const presentation_flow = @import("battle_presentation_flow.zig");
const damage_rules = @import("battle_damage");
const field = @import("field");
const battle_systems = @import("battle_systems");
const status_systems = battle_systems.status;
const battle_host_systems = battle_systems.host;
const systems = @import("battle_rules");
const battle = @import("battle.zig");
const types_mod = @import("battle_types.zig");
const State = battle.State;
const hitsWithAccuracyPenalty = damage_rules.hitsWithAccuracyPenalty;
const critical = damage_rules.critical;
const priority = damage_rules.priority;
const Protection = types_mod.Protection;
const Effect = types_mod.Effect;

pub fn resolveCommanderOrder(self: *State) void {
    const effect = &self.active.?;
    const command = self.enemy(effect.actor - self.partyCount()).commander_order.?;
    const child = &effect.ordered.?;
    const timing = self.enemy(child.actor - self.partyCount()).ordered_attack.?;
    const child_tick = self.action_ticks -| (command.launch_tick - 1);
    if (self.action_ticks == command.launch_tick) {
        child.started = true;
        self.acted[child.actor] = true;
        self.coordinator.?.stage = .select;
        self.coordinator.?.remaining = 60;
    }
    if (self.action_ticks == command.owner_release_tick) {
        effect.owner_released = true;
        if (self.coordinator.?.current_actor == effect.actor) self.coordinator.?.completed = true;
    }
    if (child_tick == timing.impact_tick) {
        effect.target_reacting = true;
        effect.amount = self.resolvePhysicalDamage(child.actor, effect.target, self.roll(), self.actions[effect.target] != null and self.actions[effect.target].? == .defend);
        if (self.actor_conditions[effect.target].protection_rounds > 0) effect.amount = 0;
        const target = &self.progress.party[effect.target];
        target.hp = @intCast(@as(u32, target.hp) -| effect.amount);
        self.markPartyKnockout(effect.target);
    }
    if (child_tick == timing.return_tick) {
        child.returning = true;
        if (self.coordinator.?.current_actor == child.actor) self.coordinator.?.completed = true;
    }
    if (child_tick == timing.status_tick and !self.statusImmune(effect.target)) {
        // The original status attempt precedes down-state commitment, even after HP reaches zero.
        if (systems.statusPercent(self.roll()) < timing.status_percent) self.actor_conditions[effect.target].accuracy_reduced = true;
    }
    if (child_tick == timing.target_release_tick) {
        effect.target_reacting = false;
        child.target_released = true;
        if (self.hp(effect.target) == 0) {
            child.target_down = self.commitPartyKnockout(effect.target);
        }
    }
}
pub fn protectorReleaseTick(self: *const State, effect: Effect) u16 {
    const profile = self.enemy(effect.actor - self.partyCount());
    const timing = profile.ordinary_timing.?;
    return timing.impact_tick + if (profile.action_policy == .roc) timing.target_release_delay.? else self.content.protection.?.hurt_duration - 1;
}
pub fn wardReturnTick(self: *const State, effect: Effect) u16 {
    return self.protectorReleaseTick(effect) + effect.protector_revival_delay + @intFromBool(effect.protector.? > effect.target);
}
pub fn coverDuration(self: *const State, effect: Effect) u16 {
    const ordinary = self.enemy(effect.actor - self.partyCount()).ordinary_timing.?.duration;
    return if (effect.protector != null) @max(ordinary, self.wardReturnTick(effect) + self.content.protection.?.ward_return_duration) else ordinary;
}
pub fn protector(self: *const State, target: usize) !?usize {
    if (target >= self.partyCount()) return error.InvalidProtectionTarget;
    const ward = self.progress.party[target];
    if (ward.hp >= ward.max_hp / 4) return null;
    if (self.integration) |_| return self.integratedProtector(target);
    const data = self.content.protection orelse return error.MissingBattleProtectionData;
    // Only settled actors are modeled; overlapping locks/pending damage need the shared scheduler.
    if (self.active != null) return error.ProtectionActorsBusy;
    for (data.pairs) |pair| {
        if (!std.mem.eql(u8, pair.ward, ward.id)) continue;
        for (self.progress.party, 0..) |member, candidate| {
            if (candidate != target and self.participates(candidate) and std.mem.eql(u8, member.id, pair.protector)) return candidate;
        }
    }
    if (!self.hasRune(target, "phero")) return null;
    const ward_type = data.characterType(ward.id) orelse return error.MissingBattleProtectionData;
    for (1..self.partyCount()) |step| {
        const candidate = (target + step) % self.partyCount();
        if (!self.participates(candidate)) continue;
        const candidate_type = data.characterType(self.progress.party[candidate].id) orelse return error.MissingBattleProtectionData;
        if (candidate_type != ward_type) return candidate;
    }
    return null;
}

/// Protection: the source selector is strict `hp < trunc(max_hp/4)`
/// (already checked by the caller), ordered `0x8016C814` pairs in the
/// 04_PLAY one-byte id space, party-order scan, eligibility and no self.
/// Phero falls back to the first active unlocked member with a different
/// exported character type, scanning forward and wrapping before the ward.
pub fn integratedProtector(self: *const State, target: usize) !?usize {
    const host = self.integrationHost() orelse return error.MissingBattleProtectionData;
    _ = host;
    var combatants: [6]status_systems.interaction.Combatant = undefined;
    for (0..self.partyCount()) |index| {
        const native = self.characterId(index) orelse return error.MissingBattleProtectionData;
        const values = self.stats(index);
        combatants[index] = .{
            .native_id = native,
            .character_type = if (self.content.protection) |protection| protection.characterType(self.progress.party[index].id) else null,
            .side = .party,
            .source_slot = @intCast(index + 1),
            .hp = self.progress.party[index].hp,
            .max_hp = self.progress.party[index].max_hp,
            .attack = values.attack,
            .defense = values.defense,
            .skill = values.skill,
            .luck = values.luck,
            .rune = self.runeByteFor(index) orelse 0,
            .defending = self.actions[index] != null and self.actions[index].? == .defend,
            .active = self.participates(index),
            .locked = self.coordinatorLocked(index),
        };
    }
    return status_systems.interaction.selectProtector(combatants[target], combatants[0..self.partyCount()]);
}

pub fn integrationHost(self: *const State) ?*const battle_host_systems.Host {
    return if (self.integration) |value| value.host else null;
}

pub fn protectionFailure(self: *State, err: anyerror) void {
    self.replay_unsupported = if (err == error.UnsupportedPheroFallback) .phero_fallback else .missing_protection;
}

const TargetDraws = struct {
    state: *State,
    pub fn next(self: TargetDraws) !u15 {
        const value = self.state.roll();
        if (self.state.replay_exhausted) return error.RandomInputExhausted;
        return value;
    }
};
fn sourceTargetStillActive(self: *const State, target: usize) bool {
    return !self.departed[target] and (self.participates(target) or self.party_knockouts[target].pending or !self.partyInactive(target));
}
fn startSelectedEnemyBranch(self: *State, actor: usize, recipient: usize) void {
    self.enemy_branch_selection = .{ .owner = @intCast(actor), .recipient = @intCast(recipient) };
    var waiting = self.active != null;
    for (0..self.partyCount()) |member| if (!battle.revival.committedPartyInactive(self.*, member) and
        (self.party_knockouts[member].pending or self.coordinatorLocked(member)))
    {
        waiting = true;
    };
    if (waiting) {
        // A pending-only tick cannot advance the active effect.
        if (self.active == null) self.pending_enemy_actor = actor;
        self.acted[actor] = false;
        return;
    }
    const started = if (self.enemy(actor - self.partyCount()).action_policy == .source_ninja) self.beginEnemySpecial(actor, recipient) else self.beginEnemyMagic(actor, recipient);
    started catch {
        self.replay_unsupported = .coordinator_action;
        return;
    };
    self.enemy_branch_selection = null;
    if (self.enemy(actor - self.partyCount()).action_policy == .source_ninja) {
        self.acted[actor] = true;
        if (self.coordinator) |*clock| {
            clock.stage = .select;
            clock.remaining = 0;
        }
    }
}
pub fn hasSourceAnt(self: *const State, actor: usize) bool {
    if (actor < self.partyCount() or actor >= self.partyCount() + self.enemyCount()) return false;
    if (self.enemy(actor - self.partyCount()).action_policy != .ant_double_strike) return false;
    const bundle = self.unite_actors orelse return false;
    const packet = bundle.counterPacket() orelse return false;
    const binding = packet.meleeEnemy(self.enemy(actor - self.partyCount()).id) orelse return false;
    return binding.special != null;
}
pub fn scanSourceEnemyTarget(self: *State, actor: usize, eligible: *bool) !?usize {
    const enemy = self.enemy(actor - self.partyCount());
    const whip_wolf = enemy.action_policy == .source_whip_wolf;
    const holly_fairy = enemy.action_policy == .source_holly_fairy;
    const regional = if (self.unite_actors) |bundle| bundle.regionalFor(enemy.id) else null;
    var party: [6]battle_systems.enemy.PartyRow = undefined;
    for (0..self.partyCount()) |target| party[target] = .{ .slot = @intCast(self.formationSlot(target)), .front = self.partyRow(target) == .front, .active = sourceTargetStillActive(self, target), .locked = !self.participates(target) or self.coordinatorLocked(target) };
    const selected = try battle_systems.enemy.scanTargets(.{
        .front_only = if (regional) |binding| binding.target_row == .front else !whip_wolf and (holly_fairy or enemy.target_policy != .any_row),
        .draw_kind = if (whip_wolf) .scale_100_32767 else .percent_100,
        .accept_at_least = if (regional) |binding| binding.front_roll_threshold else 51,
    }, party[0..self.partyCount()], TargetDraws{ .state = self }, eligible);
    return if (selected) |selection| selection.index else null;
}
pub fn sourceEnemyDecision(self: *State, actor: usize) void {
    self.pending_enemy_actor = null;
    if (self.enemy_branch_selection) |pending| {
        if (pending.owner != actor) {
            self.replay_unsupported = .enemy_policy;
            return;
        }
        startSelectedEnemyBranch(self, actor, pending.recipient);
        return;
    }
    const bundle = self.unite_actors orelse {
        self.replay_unsupported = .enemy_policy;
        return;
    };
    const packet = bundle.counterPacket() orelse {
        self.replay_unsupported = .enemy_policy;
        return;
    };
    const enemy = self.enemy(actor - self.partyCount());
    if (packet.meleeEnemy(enemy.id) == null) {
        self.replay_unsupported = .enemy_policy;
        return;
    }
    if ((enemy.action_policy == .source_ninja or enemy.action_policy == .source_dagon or enemy.action_policy == .source_creeper or enemy.action_policy == .source_mirage_f or enemy.action_policy == .source_mirage_h) and packet.meleeEnemy(enemy.id).?.special == null) {
        self.replay_unsupported = .enemy_policy;
        return;
    }
    if ((enemy.action_policy == .source_creeper or enemy.action_policy == .source_shadow_man or enemy.action_policy == .source_mirage_f or enemy.action_policy == .source_mirage_h) and bundle.regionalFor(enemy.id) == null) {
        self.replay_unsupported = .enemy_policy;
        return;
    }
    if ((enemy.action_policy == .source_sorcerer or enemy.action_policy == .source_siren or enemy.action_policy == .source_earth_golem) and bundle.areaMagicFor(enemy.id) == null) {
        self.replay_unsupported = .enemy_policy;
        return;
    }
    const whip_wolf = self.enemy(actor - self.partyCount()).action_policy == .source_whip_wolf;
    const holly_fairy = self.enemy(actor - self.partyCount()).action_policy == .source_holly_fairy;
    if (holly_fairy) {
        if (!self.hasSourceEnemyWave(actor)) {
            self.replay_unsupported = .enemy_policy;
            return;
        }
        if (self.enemyRow(actor - self.partyCount()) == .back) {
            self.beginSourceEnemyWave(actor) catch {
                self.replay_unsupported = .coordinator_action;
            };
            return;
        }
    }
    if (whip_wolf) {
        if (!self.hasSourceCommander(actor)) {
            self.replay_unsupported = .enemy_policy;
            return;
        }
        if (self.enemyRow(actor - self.partyCount()) == .back) {
            self.beginSourceCommander(actor, null) catch {
                self.replay_unsupported = .coordinator_action;
            };
            return;
        }
    }
    var eligible = false;
    const selected = scanSourceEnemyTarget(self, actor, &eligible) catch return;
    if (selected) |target| {
        if (enemy.action_policy == .source_magic or enemy.action_policy == .source_ninja or enemy.action_policy == .source_sorcerer or enemy.action_policy == .source_siren or enemy.action_policy == .source_earth_golem) {
            const draw = self.roll();
            if (self.replay_exhausted) return;
            const threshold: u32 = if (bundle.areaMagicFor(enemy.id)) |area| area.special_reject_below else 51;
            if (@as(u32, draw) * 100 / 32767 >= threshold) {
                startSelectedEnemyBranch(self, actor, target);
                return;
            }
        }
        var delay: i32 = 0;
        if (bundle.regionalFor(enemy.id)) |regional| {
            if (regional.special_roll_threshold) |threshold| {
                const draw = self.roll();
                if (self.replay_exhausted) return;
                if (@as(u32, draw) * 100 / 32767 >= threshold) {
                    self.beginEnemySpecial(actor, target) catch {
                        self.replay_unsupported = .coordinator_action;
                        return;
                    };
                    delay = regional.special_delay_updates orelse 0;
                } else if (!self.sourceEnemyAttack(actor, target)) return;
            } else if (regional.direct_attack) {
                self.beginMelee(actor, target, true) catch {
                    self.replay_unsupported = .coordinator_action;
                    return;
                };
                if (self.coordinator) |*clock| clock.cross_side_pending = true;
            } else if (regional.rear_triggers_special and self.partyRow(target) == .back) {
                self.beginEnemySpecial(actor, target) catch {
                    self.replay_unsupported = .coordinator_action;
                    return;
                };
            } else if (!self.sourceEnemyAttack(actor, target)) return;
            self.acted[actor] = true;
            if (self.coordinator) |*clock| {
                clock.stage = .select;
                clock.remaining = delay;
            }
            return;
        } else if (self.enemy(actor - self.partyCount()).action_policy == .source_dagon) {
            const special = self.roll() % 100 >= 76;
            if (self.replay_exhausted) return;
            if (special) {
                self.beginEnemySpecial(actor, target) catch {
                    self.replay_unsupported = .coordinator_action;
                    return;
                };
                self.acted[actor] = true;
                if (self.coordinator) |*clock| {
                    clock.stage = .select;
                    clock.remaining = 0;
                }
                return;
            }
        }
        if (self.hasSourceAnt(actor)) {
            const special = types_mod.antSpecial(self.roll());
            if (self.replay_exhausted) return;
            if (special) {
                self.beginEnemySpecial(actor, target) catch {
                    self.replay_unsupported = .coordinator_action;
                    return;
                };
                delay = 20;
            } else if (!self.sourceEnemyAttack(actor, target)) return;
        } else if (!self.sourceEnemyAttack(actor, target)) return;
        self.acted[actor] = true;
        if (self.coordinator) |*clock| {
            clock.stage = .select;
            clock.remaining = delay;
        }
    } else if (!holly_fairy and (eligible or whip_wolf)) {
        if (self.active == null) self.pending_enemy_actor = actor;
        self.acted[actor] = false;
    } else {
        self.acted[actor] = true;
        if (self.coordinator) |*clock| {
            clock.stage = .select;
            clock.completed = true;
            clock.remaining = 0;
        }
    }
}

pub fn sourceEnemyAttack(self: *State, actor: usize, target: usize) bool {
    const hit = hitsWithAccuracyPenalty(self.stats(actor).skill, self.stats(target).skill, self.roll(), self.hasRune(target, "hazy"));
    if (self.replay_exhausted) return false;
    const counter = if (!hit) self.counterAvailable(actor, target) catch {
        if (!self.replay_exhausted) self.replay_unsupported = .coordinator_action;
        return false;
    } else false;
    if (counter) self.beginCounter(actor, target) catch {
        self.replay_unsupported = .coordinator_action;
        return false;
    } else {
        const resolved_hit = hit or self.enemy(actor - self.partyCount()).unavoidable_attack;
        const guard = if (resolved_hit) self.protector(target) catch |err| {
            self.protectionFailure(err);
            return false;
        } else null;
        const started = if (guard) |protector_index| self.beginCover(actor, target, protector_index) else self.beginMelee(actor, target, resolved_hit);
        started catch {
            self.replay_unsupported = .coordinator_action;
            return false;
        };
    }
    return true;
}

pub fn frontProjectileDecision(self: *State, actor: usize) bool {
    self.pending_enemy_actor = null;
    self.acted[actor] = true;
    if (self.coordinator == null) {
        self.coordinator = .{ .stage = .select, .current_actor = actor, .cached = .round_end, .elapsed = 1 };
        self.action_ticks = 1;
    }
    var potential = false;
    for (0..self.partyCount()) |target| {
        if (!sourceTargetStillActive(self, target) or self.partyRow(target) != .front) continue;
        potential = true;
        if (!self.participates(target) or self.coordinatorLocked(target) or self.roll() % 100 < 51) continue;
        if (self.content.world_art != null and self.content.world_art.?.c_tracks != null and target >= 2) {
            self.replay_unsupported = .coordinator_action;
            return false;
        }
        const hit = hitsWithAccuracyPenalty(self.stats(actor).skill, self.stats(target).skill, self.roll(), self.hasRune(target, "hazy"));
        // shortcut: interception/counters and other low-HP targets need their own C tracks.
        const low_hp = self.hp(target) < self.progress.party[target].max_hp / 4;
        if (low_hp) {
            const guard = self.protector(target) catch |err| {
                self.protectionFailure(err);
                return false;
            };
            const tracks = if (self.content.world_art) |art| if (art.c_tracks) |current| current.low_hp else null else null;
            if (guard != null or target != 1 or tracks == null or self.actions[target] == null or self.actions[target].? != .defend) {
                self.replay_unsupported = .coordinator_action;
                return false;
            }
        }
        const release: ?u16 = if (hit) null else for (self.enemy(actor - self.partyCount()).front_projectile.?.dodges) |dodge| {
            if (std.mem.eql(u8, dodge.id, self.progress.party[target].id)) break dodge.target_release_tick;
        } else {
            self.replay_unsupported = .coordinator_action;
            return false;
        };
        if (!hit and self.content.world_art != null and self.content.world_art.?.c_tracks.?.misses == null) {
            self.replay_unsupported = .coordinator_action;
            return false;
        }
        self.front_projectiles[actor - self.partyCount()] = .{ .actor = actor, .target = target, .dodge_release = release, .low_hp_target = low_hp };
        self.dodge_idle_at[actor - self.partyCount()] = null;
        self.coordinator.?.stage = .select;
        self.coordinator.?.remaining = 0;
        self.coordinator.?.completed = true;
        return true;
    }
    if (potential) {
        if (self.active == null) self.pending_enemy_actor = actor;
        self.acted[actor] = false;
        return false;
    }
    self.coordinator.?.stage = .select;
    self.coordinator.?.completed = true;
    self.coordinator.?.remaining = 0;
    return true;
}
pub fn advanceFrontProjectiles(self: *State) void {
    for (&self.front_projectiles) |*maybe| {
        const shot = if (maybe.*) |*value| value else continue;
        const timing = self.enemy(shot.actor - self.partyCount()).front_projectile.?;
        shot.ticks += 1;
        if (shot.ticks == timing.impact_tick and shot.dodge_release == null) {
            const repeated = self.front_hurt_at[shot.target] != null;
            if (repeated) if (self.content.world_art) |art| if (art.c_tracks != null and art.c_tracks.?.repeated_hurt == null) {
                self.replay_unsupported = .coordinator_action;
                return;
            };
            const defending = self.actions[shot.target] != null and self.actions[shot.target].? == .defend;
            const damage = self.resolvePhysicalDamage(shot.actor, shot.target, self.roll(), defending);
            const target = &self.progress.party[shot.target];
            target.hp = @intCast(@as(u32, target.hp) -| (if (self.actor_conditions[shot.target].protection_rounds == 0) damage else 0));
            self.markPartyKnockout(shot.target);
            self.front_hurt_at[shot.target] = self.presentation_tick;
            self.front_hurt_repeated[shot.target] = repeated;
        }
        if (shot.ticks == (shot.dodge_release orelse timing.target_release_tick)) {
            shot.target_released = true;
            if (self.hp(shot.target) == 0) _ = self.commitPartyKnockout(shot.target);
        }
        if (shot.ticks == timing.owner_release_tick) shot.owner_released = true;
        if (shot.owner_released and shot.target_released) maybe.* = null;
    }
}
pub fn rocDecision(self: *State, actor: usize) void {
    // shortcut: one source Roc opens the coordinator; extend other enemy/action combinations with complete witnesses.
    if (self.enemyCount() != 1 or (self.coordinator != null and self.coordinator.?.stage != .dispatch) or self.partyStrike() != null) {
        self.replay_unsupported = .coordinator_action;
        return;
    }
    self.pending_enemy_actor = null;
    self.acted[actor] = true;
    var eligible = false;
    for (0..self.partyCount()) |target| {
        if (!sourceTargetStillActive(self, target) or self.partyRow(target) != .front) continue;
        const living = self.participates(target);
        eligible = true;
        if (!living or self.coordinatorLocked(target)) continue;
        if (self.roll() % 100 < 51) continue;
        if (self.content.world_art != null and target != 0) {
            self.replay_unsupported = .coordinator_action;
            return;
        }
        // Roc consumes accuracy before its source mask8 forces the hit; mask1 is clear.
        _ = self.roll();
        const guard = self.protector(target) catch |err| {
            self.protectionFailure(err);
            return;
        };
        // shortcut: bound cover has a complete Gremio/Defend track; extend other protectors/actions with witnesses.
        if (guard) |protector_index| if (target != 0 or protector_index != 1 or !std.mem.eql(u8, self.progress.party[0].id, "hero") or !std.mem.eql(u8, self.progress.party[1].id, "gremio") or self.actions[protector_index] == null or self.actions[protector_index].? != .defend or self.actor_conditions[protector_index].sleep_turns > 0) {
            self.replay_unsupported = .missing_protection;
            return;
        };
        const settled = self.roc_idle_at != null and !self.roc_home_restored;
        if (settled and guard != null) {
            self.replay_unsupported = .missing_protection;
            return;
        }
        self.roc_attack_from_settled = settled;
        self.roc_cover = guard != null;
        self.roc_home_restored = false;
        self.active = .{ .actor = actor, .target = target, .protector = guard, .kind = .attack, .damage_at_impact = true, .started_at = if (self.coordinator) |clock| clock.elapsed - 1 else 0 };
        if (self.coordinator) |*clock| {
            clock.stage = .select;
            clock.remaining = 0;
        } else {
            self.coordinator = .{ .stage = .select, .current_actor = actor, .cached = .round_end };
            self.action_ticks = 1;
        }
        return;
    }
    if (eligible) {
        // The pending-only path does not advance a legacy active effect.
        if (self.active == null) self.pending_enemy_actor = actor;
        self.acted[actor] = false;
    } else if (self.coordinator) |*clock| {
        clock.stage = .select;
        clock.completed = true;
        clock.remaining = 0;
    }
}
pub fn rabbitDecision(self: *State, actor: usize) void {
    if (self.enemy(actor - self.partyCount()).action_policy == .source_rabbit and !self.hasSourceRabbit(actor)) {
        self.replay_unsupported = .enemy_policy;
        return;
    }
    self.pending_enemy_actor = null;
    self.acted[actor] = true;
    const trigger = @as(u32, self.roll()) * 100 / 32767;
    if (trigger >= 51) {
        const target = (@as(usize, self.roll()) * 100 / 32767) % self.partyCount();
        if (self.participates(target) and !self.coordinatorLocked(target)) {
            if (self.hasSourceRabbit(actor)) {
                const started = self.beginRabbitProjectile(actor, target) catch {
                    self.replay_unsupported = .coordinator_action;
                    return;
                };
                if (started) {
                    if (self.coordinator) |*clock| {
                        clock.stage = .select;
                        clock.remaining = 0;
                    }
                    return;
                }
            } else {
                // shortcut: legacy packets have flattened projectile clocks; current source packets use the shared actor pool.
                self.active = .{ .actor = actor, .target = target, .kind = .attack, .damage_at_impact = true, .projectile = true, .projectile_alive = true };
                self.action_ticks = 1;
                return;
            }
        }
    }
    var eligible = false;
    for (0..self.partyCount()) |target| {
        if (!sourceTargetStillActive(self, target) or self.partyRow(target) != .front) continue;
        const living = self.participates(target);
        eligible = true;
        if (!living or self.coordinatorLocked(target)) continue;
        if (@as(u32, self.roll()) * 100 / 32767 < 51) continue;
        // Rabbit rolls accuracy; source mask8 forces the hit and mask1 rules out counters.
        _ = self.roll();
        const interceptor = self.protector(target) catch |err| {
            self.protectionFailure(err);
            return;
        };
        if (self.hasSourceRabbit(actor)) {
            if (interceptor) |guard| self.beginCover(actor, target, guard) catch {
                self.replay_unsupported = .coordinator_action;
            } else self.beginMelee(actor, target, true) catch {
                self.replay_unsupported = .coordinator_action;
            };
            if (self.coordinator) |*clock| {
                clock.stage = .select;
                clock.remaining = 0;
            }
            return;
        }
        self.active = .{ .actor = actor, .target = target, .protector = interceptor, .kind = .attack, .damage_at_impact = true };
        self.action_ticks = 1;
        return;
    }
    // A rejected pass retries this actor next update, without new priority rolls.
    if (eligible) {
        if (self.active == null) self.pending_enemy_actor = actor;
        self.acted[actor] = false;
    } else if (self.hasSourceRabbit(actor)) {
        if (self.coordinator) |*clock| {
            clock.stage = .select;
            clock.completed = true;
            clock.remaining = 0;
        }
    }
}
pub fn nextDoubleBeatTarget(self: *const State, actor: usize, current: usize) ?usize {
    if (!self.canStartAttack(actor) or current >= self.enemyCount() or !self.double_beat_pending[actor] or !self.hasRune(actor, "double-beat")) return null;
    // The original stop-before-wrap comparison can revisit only the first current enemy.
    for (1..self.enemyCount() + @intFromBool(current == 0)) |step| {
        const target = (current + step) % self.enemyCount();
        if (self.enemy_hp[target] > 0) return if (self.sharedPartyMelee() or self.canAttackTarget(actor, target)) target else null;
    }
    return null;
}
pub fn followupTarget(self: *const State, effect: Effect) ?usize {
    if ((effect.kind != .attack and effect.kind != .miss) or effect.rune_attack or effect.actor >= self.partyCount() or effect.target < self.partyCount()) return null;
    const enemy = self.nextDoubleBeatTarget(effect.actor, effect.target - self.partyCount()) orelse return null;
    return self.partyCount() + enemy;
}
pub fn usesProfileAttack(self: *const State, enemy_index: usize) bool {
    if (enemy_index >= self.enemyCount() or self.content.world_art != null or self.enemy(enemy_index).action_policy != .attack) return false;
    const packet = (self.unite_actors orelse return false).counterPacket() orelse return false;
    // shortcut: use the profile's physical presentation until this enemy has actor tracks.
    return packet.animations.find(self.enemy(enemy_index).id) == null;
}

pub const AttackMode = union(enum) {
    ordinary,
    enemy_special,
    followup: usize, // Previous target actor index.
};

pub fn beginAttack(self: *State, actor: usize, requested_target: usize, mode: AttackMode) void {
    self.presentation = null;
    self.presentation_refusal = "";
    const party_count = self.partyCount();
    const party_actor = actor < party_count;
    const previous_target = if (mode == .followup) mode.followup else null;
    var target = requested_target;
    // shortcut: retarget the first survivor; add original target policies with enemy AI.
    if (party_actor) {
        if (!self.canStartAttack(actor)) {
            self.active = .{ .actor = actor, .target = actor, .kind = .unavailable };
            return;
        }
        const shared_melee = self.sharedPartyMelee();
        if (target < party_count or target >= party_count + self.enemyCount() or
            (if (shared_melee) !self.participates(target) else !self.canAttackTarget(actor, target - party_count)))
        {
            target = (if (shared_melee) self.firstLiving(false) else if (self.firstAttackTarget(actor)) |enemy| party_count + enemy else null) orelse {
                self.active = .{ .actor = actor, .target = actor, .kind = .unavailable };
                return;
            };
        }
    } else if (target >= party_count or !self.participates(target)) target = self.firstLiving(true).?;
    const profile_attack = self.usesProfileAttack(if (party_actor) target - party_count else actor - party_count);
    if (party_actor and !profile_attack) if (self.unite_actors) |bundle| if (bundle.counterPacket()) |packet| {
        if (packet.partyAttacker(self.progress.party[actor].id, .melee_hit) != null) {
            if (!self.startMeleeStrike(actor, target - party_count) and self.replay_unsupported == null and !self.replay_exhausted) self.acted[actor] = false;
            if (self.active) |*effect| if (effect.actor == actor and effect.counter_attack) {
                effect.followup_from = previous_target;
                effect.retargeted_from = if (target != requested_target) requested_target else null;
            };
            return;
        }
        if (packet.rangedAttacker(self.progress.party[actor].id) != null) {
            if (!self.startRangedStrike(actor, target - party_count) and self.replay_unsupported == null and !self.replay_exhausted) self.acted[actor] = false;
            return;
        }
    };
    if (party_actor and self.hasRune(actor, "double-beat")) self.double_beat_pending[actor] = !self.double_beat_pending[actor];
    if (party_actor and self.hasRune(actor, "spark")) self.spark_pending = true;
    const defending = target < party_count and self.actions[target] != null and self.actions[target].? == .defend;
    if (mode == .enemy_special) {
        self.active = .{ .actor = actor, .target = target, .kind = .attack, .enemy_special = true, .amount = self.resolvePhysicalDamage(actor, target, self.roll(), defending) * 2 };
        return;
    }
    const rolled_hit = hitsWithAccuracyPenalty(self.stats(actor).skill, self.stats(target).skill, self.roll(), if (party_actor) self.actor_conditions[actor].accuracy_reduced else target < party_count and self.hasRune(target, "hazy"));
    if (!rolled_hit and party_actor and !profile_attack) {
        const parry = self.parryAvailable(actor, target) catch {
            self.replay_unsupported = .coordinator_action;
            return;
        };
        if (parry) {
            self.beginParry(actor, target) catch {
                self.replay_unsupported = .coordinator_action;
                return;
            };
            self.active.?.followup_from = previous_target;
            self.active.?.retargeted_from = if (target != requested_target) requested_target else null;
            return;
        }
    }
    if (!rolled_hit and !party_actor and !profile_attack) {
        // shortcut: ordinary misses only; extend with each source-qualified special-action policy.
        const counter = self.counterAvailable(actor, target) catch |err| {
            if (err == error.RandomInputExhausted) self.replay_exhausted = true else self.replay_unsupported = .coordinator_action;
            return;
        };
        if (counter) {
            self.beginCounter(actor, target) catch |err| {
                if (err == error.RandomInputExhausted) self.replay_exhausted = true else self.replay_unsupported = .coordinator_action;
            };
            return;
        }
    }
    const connected = rolled_hit or (if (party_actor) !self.enemy(target - party_count).dodges_attacks else self.enemy(actor - party_count).unavoidable_attack);
    const strike = party_actor and connected and critical(self.stats(actor).skill, self.stats(actor).luck, self.hasRune(actor, "killer"), self.roll());
    self.active = .{ .actor = actor, .target = target, .kind = if (connected) .attack else .miss, .critical = strike, .followup_from = previous_target, .amount = if (connected) self.resolvePhysicalDamage(actor, target, self.roll(), defending) * @as(u32, if (strike) 3 else 1) else 0, .retargeted_from = if (target != requested_target) requested_target else null };
    if (party_actor) presentation_flow.beginAttackPresentation(self, actor);
}
pub fn chooseEnemyTarget(self: *State, enemy_index: usize) ?usize {
    if (enemy_index >= self.enemyCount()) return null;
    if (self.enemy(enemy_index).target_policy == .random) {
        const target = @as(usize, self.roll()) % self.partyCount();
        return if (self.participates(target)) target else self.firstLiving(true);
    }
    var eligible = false;
    for (0..self.partyCount()) |i| if (self.participates(i) and (self.enemy(enemy_index).target_policy == .any_row or self.partyRow(i) == .front)) {
        eligible = true;
        break;
    };
    if (!eligible) return null;
    while (true) for (0..self.partyCount()) |i| {
        if (!self.participates(i) or (self.enemy(enemy_index).target_policy == .front_first and self.partyRow(i) != .front)) continue;
        if (self.roll() % 100 >= 51) return i;
    };
}
pub fn applyFieldStatuses(self: *State) void {
    for (self.progress.party) |*member| {
        if (member.status != .poisoned) continue;
        const result = systems.fieldPoison(member.hp, member.max_hp, self.roll());
        if (result.cured) member.status = .healthy;
        member.hp -= result.damage;
    }
}
pub fn castFieldSpell(self: *State, actor: usize, spell: usize, target: usize) !void {
    if (actor >= self.partyCount() or self.content.systems == null or spell >= self.content.systems.?.spells.len) return error.InvalidSpell;
    if (!self.canCast(actor, spell) or (!self.content.systems.?.spells[spell].allies or !self.content.systems.?.spells[spell].field_use) or target >= self.partyCount()) return error.InvalidSpell;
    var effect = Effect{ .actor = actor, .target = target, .kind = .cast, .spell = spell };
    self.applySpell(&effect);
    if (effect.kind == .unavailable) return error.InvalidTarget;
}
pub fn gearIndex(self: State, id: field.items.Id) ?usize {
    const rules = self.content.systems orelse return null;
    for (rules.equipment, 0..) |gear, i| if (std.mem.eql(u8, gear.id, @tagName(id))) return i;
    return null;
}
pub fn depositToStorage(self: *State, store: *field.game_state.storage.Storage, owner: usize, slot: usize) !void {
    if (owner >= self.partyCount() or slot >= self.progress.party[owner].inventory.count()) return error.InvalidItem;
    if (self.itemEquipped(owner, slot)) return error.EquippedItem;
    try store.deposit(&self.progress.party[owner].inventory, slot);
}
pub fn gearCount(self: State, member: usize, item: usize) usize {
    const id = std.meta.stringToEnum(field.items.Id, self.content.systems.?.equipment[item].id) orelse return 0;
    var count: usize = 0;
    for (self.progress.party[member].inventory.slots) |slot| if (slot != null and slot.?.id == id) {
        count += 1;
    };
    return count;
}
pub fn itemEquipped(self: State, member: usize, slot: usize) bool {
    const item = self.progress.party[member].inventory.slots[slot] orelse return false;
    var worn: usize = 0;
    for (std.enums.values(systems.EquipmentSlot)) |place| if (self.progress.party[member].loadout.get(place)) |gear| {
        if (std.mem.eql(u8, @tagName(item.id), self.content.systems.?.equipment[gear].id)) worn += 1;
    };
    for (self.progress.party[member].inventory.slots[0..slot]) |other| if (other != null and other.?.id == item.id) {
        worn -|= 1;
    };
    return worn > 0;
}
pub fn equipOwned(self: *State, member: usize, item: ?usize) !void {
    try self.equipSlotOwned(member, .head, item);
}
pub fn equipSlotOwned(self: *State, member: usize, slot: systems.EquipmentSlot, item: ?usize) !void {
    try self.checkEquipment(member, slot, item);
    try self.equipSlot(member, slot, item);
}
pub fn checkEquipment(self: State, member: usize, slot: systems.EquipmentSlot, item: ?usize) !void {
    if (member >= self.partyCount() or self.content.systems == null) return error.InvalidEquipment;
    if (item) |id| {
        if (id >= self.content.systems.?.equipment.len or !self.content.systems.?.equipment[id].allows(self.partyProfile(member).id, slot)) return error.InvalidEquipment;
        var needed: usize = 1;
        for (std.enums.values(systems.EquipmentSlot)) |other| if (other != slot and self.progress.party[member].loadout.get(other) == item) {
            needed += 1;
        };
        if (self.gearCount(member, id) < needed) return error.ItemUnavailable;
    }
}
