const std = @import("std");
const rewards = @import("battle_rewards");
const status = @import("battle_status");
const battle_systems = @import("battle_systems");
const status_systems = battle_systems.status;
const spell_systems = battle_systems.spells;
const battle_host_systems = battle_systems.host;
const systems = @import("battle_rules");
const battle = @import("battle.zig");
const types_mod = @import("battle_types.zig");
const State = battle.State;
const Effect = types_mod.Effect;

pub fn enemyAffinity(self: State, enemy_index: usize, element: systems.Element) systems.Affinity {
    const profile = self.enemy(enemy_index);
    if (profile.affinities) |values| return values.get(element);
    return if (element == .fire) profile.fire_affinity else .neutral;
}
pub fn spellValid(self: *const State, spell: systems.Spell, target: usize) bool {
    if (target >= self.partyCount() + self.enemyCount() or spell.allies != (target < self.partyCount())) return false;
    if (spell.kind == .revive) return target < self.partyCount() and (!self.participates(target) or (spell.full_heal and (self.hp(target) < self.progress.party[target].max_hp or self.progress.party[target].status != .healthy or self.progress.party[target].balloons > 0 or self.asleep[target] > 0 or self.accuracy_reduced[target] or self.rune_blocked[target])));
    if (!self.participates(target)) return false;
    return switch (spell.kind) {
        .heal => self.hp(target) < self.progress.party[target].max_hp or (spell.clear_status and (self.progress.party[target].status != .healthy or self.progress.party[target].balloons > 0 or self.asleep[target] > 0 or self.accuracy_reduced[target] or self.rune_blocked[target])),
        .cure => self.progress.party[target].status == .poisoned or self.progress.party[target].balloons > 0 or self.asleep[target] > 0 or self.accuracy_reduced[target] or self.rune_blocked[target] or self.hp(target) < self.progress.party[target].max_hp,
        .sleep => self.asleep[target] == 0,
        else => true,
    };
}
pub fn spellRuleIndex(self: *const State, host: *const battle_host_systems.Host, spell_index: usize) ?usize {
    const catalogue = self.content.systems orelse return null;
    if (spell_index >= catalogue.spells.len) return null;
    return host.spellIndexForName(catalogue.spells[spell_index].name);
}

pub fn runeSpells(self: *const State, host: *const battle_host_systems.Host, member: usize) [4]?usize {
    var result: [4]?usize = @splat(null);
    const owned_rune = self.rune(member) orelse return result;
    for (owned_rune.spells, 0..) |slot, tier| {
        if (slot) |spell| result[tier] = self.spellRuleIndex(host, spell);
    }
    return result;
}

pub fn spellTarget(self: State, index: usize) spell_systems.plan.Target {
    if (index < self.partyCount()) {
        const member = self.progress.party[index];
        return .{
            .id = @intCast(index + 1),
            .side = .ally,
            .hp = member.hp,
            .max_hp = member.max_hp,
            .ko = member.status == .unconscious or self.departed[index],
            .status = self.spellStatus(index),
            .protection = self.protection[index],
            .sleep = self.asleep[index],
            .skill_bonus = self.temporary_stats[index].skill_bonus,
            .defense_bonus = self.temporary_stats[index].defense_bonus,
        };
    }
    const enemy_index = index - self.partyCount();
    var affinity: [6]systems.Affinity = @splat(.neutral);
    if (enemy_index < self.enemyCount()) {
        affinity[0] = self.enemyAffinity(enemy_index, .fire);
        affinity[1] = self.enemyAffinity(enemy_index, .water);
        affinity[2] = self.enemyAffinity(enemy_index, .earth);
        affinity[3] = self.enemyAffinity(enemy_index, .lightning);
        affinity[4] = self.enemyAffinity(enemy_index, .wind);
        affinity[5] = self.enemy(enemy_index).other_affinity orelse .neutral;
    }
    return .{
        .id = @intCast(index + 1),
        .side = .enemy,
        .hp = if (enemy_index < self.enemyCount()) self.enemy_hp[enemy_index] else 0,
        .max_hp = if (enemy_index < self.enemyCount()) self.enemy(enemy_index).max_hp else 0,
        .affinity = affinity,
        .airborne = if (enemy_index < self.enemyCount()) self.enemy(enemy_index).airborne orelse false else false,
        .death_immune = if (enemy_index < self.enemyCount()) self.enemy(enemy_index).death_immune orelse false else false,
        .ko = enemy_index >= self.enemyCount() or self.enemy_hp[enemy_index] == 0,
        .protection = self.protection[index],
        .sleep = self.asleep[index],
        .skill_bonus = self.temporary_stats[index].skill_bonus,
        .defense_bonus = self.temporary_stats[index].defense_bonus,
    };
}

pub fn spellStatus(self: State, index: usize) u16 {
    const member = self.progress.party[index];
    var mask: u16 = 0;
    if (member.status == .poisoned) mask |= status_systems.status.maskOf(.poison);
    for (0..member.balloons) |balloon| mask |= status_systems.status.maskOf(@fromBackingInt(@intCast(balloon + 1)));
    if (self.accuracy_reduced[index]) mask |= status_systems.status.maskOf(.accuracy_reduced);
    if (self.rune_blocked[index]) mask |= status_systems.status.maskOf(.rune_blocked);
    return mask;
}

/// Resolve the impact against a copy of the current targets. Publish HP,
/// statuses, charges and the draw cursor only after every target resolves.
pub fn applySpellBridge(self: *State, effect: *Effect) void {
    const host = self.integrationHost() orelse {
        effect.kind = .unavailable;
        return;
    };
    const draws = self.replay_draws orelse {
        effect.kind = .unavailable;
        return;
    };
    const system = self.content.systems orelse {
        effect.kind = .unavailable;
        return;
    };
    if (effect.spell >= system.spells.len or effect.actor >= self.partyCount()) {
        effect.kind = .unavailable;
        return;
    }
    const content_id = self.content.encounters[self.encounter].id;
    const rule_index = host.spellIndexForName(system.spells[effect.spell].name) orelse {
        effect.kind = .unavailable;
        return;
    };
    // Legacy profiles without these fields cannot establish these spell outcomes.
    for (host.spellRules().spells[rule_index].steps) |step| {
        const needs_other = step.channel == 5;
        const needs_immunity = std.mem.eql(u8, step.op, "instant_ko") or std.mem.eql(u8, step.op, "sleep");
        if (!needs_other and !needs_immunity and !step.airborne_immune) continue;
        const target_set = step.targetOf() catch {
            effect.kind = .unavailable;
            return;
        };
        for (0..self.enemyCount()) |enemy_index| {
            const index = self.partyCount() + enemy_index;
            if (self.hp(index) == 0 or target_set == .allies or target_set == .all_allies or (target_set == .selected and index != effect.target)) continue;
            const profile = self.enemy(enemy_index);
            if ((needs_other and profile.other_affinity == null) or (needs_immunity and profile.death_immune == null) or (step.airborne_immune and profile.airborne == null)) {
                effect.kind = .unavailable;
                return;
            }
        }
    }
    const rune_spells = self.runeSpells(host, effect.actor);
    const count = self.partyCount() + self.enemyCount();
    if (count > spell_systems.plan.max_targets) {
        effect.kind = .unavailable;
        return;
    }
    var targets: [spell_systems.plan.max_targets]spell_systems.plan.Target = undefined;
    var target_index: usize = 0;
    while (target_index < count) : (target_index += 1) targets[target_index] = self.spellTarget(target_index);
    const actor: spell_systems.plan.Actor = .{
        .id = @intCast(effect.actor + 1),
        .rune_index = self.runes[effect.actor] orelse 0,
        .charges = self.progress.party[effect.actor].rune_charges,
        .magic = self.stats(effect.actor).magic,
    };
    const continuation = spell_systems.plan.prepare(host.spellRules(), content_id, rune_spells, actor, .{
        .spell_index = rule_index,
        .target_id = @intCast(effect.target + 1),
    }, targets[0..count]) catch {
        effect.kind = .unavailable;
        return;
    };
    const committed = spell_systems.plan.commit(continuation) catch {
        effect.kind = .unavailable;
        return;
    };
    const before_draws = draws.*;
    var resolved = spell_systems.plan.resolve(host.spellRules(), committed, content_id, rune_spells, actor, targets[0..count], before_draws) catch |failure| {
        if (failure == error.RandomInputExhausted) {
            self.replay_exhausted = true;
        } else {
            effect.kind = .unavailable;
        }
        return;
    };
    for (resolved.changes[0..resolved.count]) |*change| {
        if (change.before.side != .ally) continue;
        // A revive step can clear the plan's KO bit before protection blocks HP recovery.
        if (change.before.ko and change.before.protection != 0 and change.after.hp == 0) change.after.ko = true;
        if ((change.after.hp == 0) != change.after.ko) {
            effect.kind = .unavailable;
            return;
        }
    }
    var staged = spell_systems.bridge.Host{
        .content_id = content_id,
        .actor = actor,
        .rune_spells = rune_spells,
        .draws = before_draws,
    };
    for (0..count) |index| staged.targets[index] = targets[index];
    staged.count = count;
    spell_systems.bridge.apply(&staged, resolved) catch {
        effect.kind = .unavailable;
        return;
    };
    effect.instant_knockouts = 0;
    effect.spell_hp_loss = 0;
    effect.affected = 0;
    effect.amounts = @splat(0);
    for (resolved.changes[0..resolved.count]) |change| {
        const index: usize = @intCast(change.before.id - 1);
        if (index >= count) continue;
        const after = staged.targets[index];
        const difference = if (after.hp >= change.before.hp) after.hp - change.before.hp else change.before.hp - after.hp;
        if (after.hp < change.before.hp) effect.spell_hp_loss |= @as(u16, 1) << @intCast(index);
        effect.amounts[index] = difference;
        effect.affected |= @as(u16, 1) << @intCast(index);
        self.temporary_stats[index] = .{ .skill_bonus = after.skill_bonus, .defense_bonus = after.defense_bonus };
        if (index < self.partyCount()) {
            const member = &self.progress.party[index];
            member.hp = after.hp;
            if (after.ko and !change.before.ko) {
                self.markPartyKnockout(index);
                if (!battle.revival.hasBuddha(self.*, index)) member.balloons = 0;
            } else if (change.before.ko and !after.ko) {
                member.status = .healthy;
                // shortcut: revival restores normal placement until its departure interaction is qualified.
                self.departed[index] = false;
                self.departures[index] = null;
                self.knockout_pending[index] = false;
                self.knockout_status[index] = null;
                if (self.actions[index] == null) self.acted[index] = true;
            }
            if (after.status == 0 and change.before.status != 0 and !(after.ko and battle.revival.hasBuddha(self.*, index))) {
                if (!after.ko) member.status = .healthy;
                member.balloons = 0;
                self.accuracy_reduced[index] = false;
                self.rune_blocked[index] = false;
            }
            self.asleep[index] = after.sleep;
            self.protection[index] = after.protection;
        } else {
            const enemy_index = index - self.partyCount();
            if (after.ko and !change.before.ko) effect.instant_knockouts |= @as(u16, 1) << @intCast(index);
            self.enemy_hp[enemy_index] = if (after.ko) 0 else after.hp;
            self.asleep[index] = after.sleep;
            self.protection[index] = after.protection;
        }
    }
    self.progress.party[effect.actor].rune_charges = staged.actor.charges;
    draws.* = staged.draws;
}

pub fn applySpell(self: *State, effect: *Effect) void {
    if (self.integration != null) {
        if (self.replay_draws != null) {
            applySpellBridge(self, effect);
        } else {
            var draws = systems.Draws{ .prng = self.random };
            self.replay_draws = &draws;
            defer self.replay_draws = null;
            applySpellBridge(self, effect);
            self.random = draws.prng.?;
        }
        return;
    }
    const spell = self.content.systems.?.spells[effect.spell];
    if (spell.kind == .source_rule) {
        effect.kind = .unavailable;
        return;
    }
    const actor = &self.progress.party[effect.actor];
    const tier = self.spellTier(effect.actor, effect.spell) orelse {
        effect.kind = .unavailable;
        return;
    };
    if (!self.canCast(effect.actor, effect.spell)) {
        effect.kind = .unavailable;
        return;
    }
    const first = if (spell.group) (if (spell.allies) @as(usize, 0) else self.partyCount()) else effect.target;
    const end = if (spell.group) first + (if (spell.allies) self.partyCount() else self.enemyCount()) else first + 1;
    for (first..end) |target| {
        if (!self.spellValid(spell, target)) continue;
        effect.affected |= @as(u16, 1) << @intCast(target);
        if (spell.kind == .damage) {
            const damage = if (self.protection[target] > 0) 0 else if (spell.element != null) systems.elementalDamage(spell.power, self.stats(effect.actor).magic, self.enemyAffinity(target - self.partyCount(), spell.element.?)) else @as(u32, spell.power) + self.stats(effect.actor).magic -| self.stats(target).magic;
            effect.amounts[target] = damage;
            self.enemy_hp[target - self.partyCount()] = @intCast(@as(u32, self.hp(target)) -| damage);
            self.asleep[target] = 0;
        } else if (spell.kind == .skill_bonus_scale) {
            self.temporary_stats[target].skill_bonus = @intCast(@divTrunc(@as(i32, self.temporary_stats[target].skill_bonus) * spell.power, 100));
        } else if (spell.kind == .defense_bonus_scale) {
            self.temporary_stats[target].defense_bonus = @intCast(@divTrunc(@as(i32, self.temporary_stats[target].defense_bonus) * spell.power, 100));
        } else if (spell.kind == .protection) {
            self.protection[target] = @intCast(spell.power);
        } else if (spell.kind == .sleep) {
            if (target >= self.partyCount() and (self.enemy(target - self.partyCount()).death_immune orelse false)) continue;
            if (spell.sleep_failure_percent) |failure| {
                if (systems.statusPercent(self.roll()) >= failure) _ = self.inflictStatus(target, .sleep);
            } else if (self.inflictStatus(target, .sleep)) self.asleep[target] = @intCast(@min(spell.power + 1, 255));
        } else {
            const member = &self.progress.party[target];
            const before = member.hp;
            if (spell.kind == .revive) {
                if (self.protection[target] == 0) member.hp = if (spell.full_heal) member.max_hp else @max(1, @as(u16, @intCast(@as(u32, member.max_hp) * spell.power / 100)));
                if (member.hp > 0) {
                    // shortcut: revival restores normal placement until its departure interaction is qualified.
                    self.departed[target] = false;
                    self.departures[target] = null;
                    self.knockout_pending[target] = false;
                    self.knockout_status[target] = null;
                    member.status = .healthy;
                    if (self.actions[target] == null) self.acted[target] = true;
                }
                member.balloons = 0;
                self.asleep[target] = 0;
                self.accuracy_reduced[target] = false;
                self.rune_blocked[target] = false;
            } else {
                if (self.protection[target] == 0) member.hp = if (spell.full_heal) member.max_hp else @intCast(@min(member.max_hp, @as(u32, member.hp) + spell.power));
                if (spell.kind == .cure or spell.clear_status) {
                    member.status = .healthy;
                    member.balloons = 0;
                    self.asleep[target] = 0;
                    self.accuracy_reduced[target] = false;
                    self.rune_blocked[target] = false;
                }
            }
            effect.amounts[target] = member.hp - before;
        }
    }
    if (effect.affected == 0) effect.kind = .unavailable else actor.rune_charges[tier] -= 1;
}
pub fn rewardReady(self: State) bool {
    return rewards.rewardReady(self);
}
pub fn commitRewards(self: *State) void {
    rewards.commitRewards(self);
}
pub fn experienceAward(self: State, index: usize) u32 {
    return rewards.experienceAward(self, index);
}

pub fn applyExperience(self: *State, index: usize) void {
    // Bounded: a legitimate award can cross several levels, but a corrupt
    // counter must not spin the reward commit.  99 is the source cap.
    var levels: u8 = 0;
    while (self.experience[index] >= 1000 and self.levels[index] < 99 and levels < 99) : (levels += 1) {
        self.experience[index] -= 1000;
        var randoms: [7]u15 = undefined;
        for (&randoms) |*value| value.* = self.roll();
        self.levelUp(index, randoms);
    }
    if (self.levels[index] == 99) self.experience[index] = 0 else if (self.experience[index] >= 1000) self.experience[index] = 999;
}
pub fn sceneExperience(self: *State, gain: bool) !void {
    if (self.content.systems == null) return error.MissingGrowthRules;
    for (0..self.partyCount()) |index| if (self.experience[index] >= 1000) return error.InvalidExperience;
    for (0..self.partyCount()) |index| {
        if (!gain) {
            self.experience[index] -|= 10;
            continue;
        }
        self.experience[index] += 10;
        if (self.experience[index] < 1000) continue;
        self.experience[index] %= 1000;
        // The event wraps EXP at the cap without consuming growth draws.
        if (self.levels[index] == 99) continue;
        var randoms: [7]u15 = undefined;
        for (&randoms) |*value| value.* = self.roll();
        self.levelUp(index, randoms);
    }
}
pub fn levelUp(self: *State, index: usize, randoms: [7]u15) void {
    if (self.levels[index] == 99) return;
    const rules = self.content.systems.?;
    self.levels[index] += 1;
    const growth = self.partyProfile(index).growth;
    var stats_ptr = &self.base_stats[index];
    const columns = [_]*u16{ &stats_ptr.attack, &stats_ptr.skill, &stats_ptr.defense, &stats_ptr.speed, &stats_ptr.magic, &stats_ptr.luck };
    for (columns, growth, 0..) |column, rate, i| {
        const gain = (rules.stat_growth[systems.statIndex(self.levels[index], rate)] + (randoms[i] & 255)) >> 8;
        column.* = @intCast(@min(255, column.* + gain));
    }
    const band: usize = if (self.levels[index] < 20) 0 else if (self.levels[index] < 60) 1 else 2;
    const gain = (rules.hp_growth[@as(usize, growth[0]) * 3 + band] + (randoms[6] & 511)) >> 8;
    const member = &self.progress.party[index];
    member.max_hp = @intCast(@min(9999, @as(u32, member.max_hp) + gain));
    member.hp = @intCast(@min(member.max_hp, @as(u32, member.hp) + gain));
    @import("battle_gear_runes.zig").refreshMagicCapacity(self, index);
}
