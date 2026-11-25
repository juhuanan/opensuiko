const std = @import("std");
const spell_scene = @import("battle_spell_scene.zig");
const systems = @import("battle_rules");
const battle = @import("battle.zig");
const types_mod = @import("battle_types.zig");
const State = battle.State;
const Stats = types_mod.Stats;
const Row = types_mod.Row;
const WeaponRange = types_mod.WeaponRange;
const PartyStrike = types_mod.PartyStrike;

pub fn resolvePhysicalDamage(self: *const State, attacker: usize, target: usize, roll: u15, defending: bool) u32 {
    const base = systems.physicalDamage(self.stats(attacker).attack, self.stats(target).defense, roll, defending and target < self.partyCount());
    if (attacker >= self.partyCount()) return base;
    const augment = self.weapon_augments[attacker];
    const weapon = if (self.partyProfile(attacker).weapon) |value| value.element else null;
    const element = systems.weaponElement(weapon, augment.rune);
    const profile = if (target < self.partyCount()) self.partyProfile(target) else self.enemy(target - self.partyCount());
    const weak = if (element) |value| (if (profile.affinities) |affinities| affinities.get(value) else if (value == .fire) profile.fire_affinity else .neutral) == .weak else false;
    return systems.physicalWeaponDamage(base, weak, augment);
}

pub fn impactTick(self: *const State) u16 {
    if (self.hasSpellScene()) return self.spell_scenes.?.spells[self.active.?.scene.?.spell].program.?.impact;
    if (self.hasDrops()) return 306;
    const effect = self.active orelse return 20;
    if (effect.kind == .enemy_magic or effect.kind == .enemy_command) return std.math.maxInt(u16);
    if (effect.kind == .group_order) return self.enemy(effect.actor - self.partyCount()).commander_order.?.launch_tick + self.enemy(effect.ordered.?.actor - self.partyCount()).ordered_attack.?.impact_tick - 1;
    if (effect.kind == .status_attack) return self.enemy(effect.actor - self.partyCount()).commander.?.status_tick;
    if (effect.kind == .cast) return self.partyProfile(effect.actor).cast_impact;
    if (effect.kind == .unite) {
        if (self.hasLiveUniteActors()) if (self.unite_vm.impact_at[effect.actor]) |at| return at;
        // The logic callback observes the hit flag before this frame's actor update.
        if (self.hasUniteTracks()) {
            if (self.activeUniteBoundary()) |boundary| {
                const host = self.integrationHost().?;
                const record = host.uniteCatalogue().recordAt(boundary.record_index).?;
                if (boundary.hitActor(record)) |member| {
                    const track = self.uniteTrack(member).?;
                    return track.start_after + track.motion.impact_tick + 1;
                }
            }
            return self.memberImpact(effect.actor) + 1;
        }
        if (self.activeUniteBoundary()) |boundary| {
            var impact: u16 = 0;
            for (boundary.participantsSlice()) |participant| impact = @max(impact, self.memberImpact(participant));
            return impact;
        }
        return @max(self.memberImpact(effect.actor), self.memberImpact(effect.partner.?));
    }
    if (effect.kind == .attack or effect.kind == .miss) return self.memberImpact(effect.actor);
    return 20;
}
pub fn animationTick(self: *const State, member: usize) u16 {
    if (self.unite_vm.owns(member)) return self.unite_vm.members[member].?.age;
    if (self.uniteReturnFor(member)) |tail| return tail.ticks -| self.uniteTrack(member).?.start_after;
    const effect = self.active orelse return 0;
    if (effect.kind == .unite and self.hasUniteTracks()) if (self.uniteTrack(member)) |track| return self.effectTicks() -| track.start_after;
    const delay = if (effect.kind == .unite and !self.hasUniteTracks()) self.impactTick() - self.memberImpact(member) else 0;
    return self.effectTicks() -| delay;
}
pub fn attackFrameTick(self: *const State, member: usize) u16 {
    const elapsed = self.animationTick(member);
    if (self.activeUniteMember(member) or self.uniteReturnFor(member) != null) {
        if (self.uniteTrack(member)) |track| if (track.motion.ready_tick == elapsed) return elapsed -| 1;
    }
    return elapsed;
}
pub fn actionDuration(self: *const State) u16 {
    if (self.hasSpellScene()) {
        const packet = self.spell_scenes.?;
        const program = packet.spells[self.active.?.scene.?.spell].program.?;
        var duration = program.duration;
        for (0..self.enemyCount()) |enemy_index| {
            const index = self.partyCount() + enemy_index;
            if (self.active.?.instant_knockouts & (@as(u16, 1) << @intCast(index)) != 0) continue;
            if (self.hp(index) != 0 or self.active.?.affected & (@as(u16, 1) << @intCast(index)) == 0) continue;
            for (packet.hurt_poses) |pose| if (std.mem.eql(u8, pose.id, self.enemy(enemy_index).id)) {
                if (pose.knockout) |ko| duration = @max(duration, spell_scene.knockoutStart(program) + ko.duration);
            };
        }
        return duration;
    }
    if (self.hasDrops()) return 307;
    const effect = self.active orelse return 52;
    if (effect.kind == .enemy_magic or effect.kind == .enemy_command) return std.math.maxInt(u16);
    if (effect.kind == .group_order) return @max(self.enemy(effect.actor - self.partyCount()).commander_order.?.owner_release_tick, self.enemy(effect.actor - self.partyCount()).commander_order.?.launch_tick + self.enemy(effect.ordered.?.actor - self.partyCount()).ordered_attack.?.duration - 1);
    if (effect.kind == .status_attack) return self.enemy(effect.actor - self.partyCount()).commander.?.duration;
    if (self.followupTarget(effect) != null) if (self.actionMotion(effect.actor)) |motion| {
        return motion.ready_tick orelse motion.return_start;
    };
    if (effect.kind == .cast) {
        const frames = self.partyProfile(effect.actor).cast;
        if (frames.len == 0) return 120;
        var total: u16 = 0;
        for (frames) |frame| total += frame.ticks;
        return total;
    }
    if (effect.kind == .unite) {
        if (self.martial_queue != null or self.hasLiveUniteActors()) return self.uniteHandoffTick() orelse std.math.maxInt(u16);
        if (self.uniteHandoffTick()) |handoff| return handoff;
        const impact = self.impactTick();
        if (self.activeUniteBoundary()) |boundary| {
            if (boundary.sequence) |sequence| return sequence.finish_at orelse std.math.maxInt(u16);
            var duration: u16 = 0;
            for (boundary.participantsSlice()) |participant| {
                const delay = if (self.hasUniteTracks()) 0 else impact - self.memberImpact(participant);
                duration = @max(duration, self.memberDuration(participant) + delay);
            }
            return duration;
        }
        if (self.hasUniteTracks()) return @max(self.memberDuration(effect.actor), self.memberDuration(effect.partner.?));
        return @max(self.memberDuration(effect.actor) + impact - self.memberImpact(effect.actor), self.memberDuration(effect.partner.?) + impact - self.memberImpact(effect.partner.?));
    }
    if (effect.kind == .attack or effect.kind == .miss) return self.memberDuration(effect.actor);
    return 52;
}
pub fn canEscape(self: *const State) bool {
    return self.escape_allowed and self.content.encounters[self.encounter].escape_allowed;
}
pub fn canLetGo(self: *const State) bool {
    if (!self.canEscape()) return false;
    var party_levels: u32 = 0;
    var enemy_levels: u32 = 0;
    for (self.levels[0..self.partyCount()]) |level| party_levels += level;
    for (0..self.enemyCount()) |i| enemy_levels += self.enemy(i).level;
    return party_levels * 60 / self.partyCount() >= enemy_levels * 60 / self.enemyCount();
}
pub fn runSucceeds(self: *const State, random: u15) bool {
    return self.canEscape() and (self.canLetGo() or random % 100 >= 51);
}
pub fn enterRoundMenu(self: *State) void {
    if (self.actor_camera) |controller| {
        self.source_camera_hold = controller.sample();
        self.actor_camera = null;
    }
    if (self.source_camera_hold) |held| {
        self.source_camera_return = .{ .from = held, .started = self.camera_ticks };
        self.source_camera_hold = null;
    }
    if (self.firstLiving(true)) |first| {
        self.choose(first);
        if (self.content.systems != null) self.phase = .battle_menu;
    } else self.phase = .defeat;
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
pub fn stats(self: *const State, index: usize) Stats {
    if (index >= self.partyCount()) return withTemporaryStats(self, index, self.enemy(index - self.partyCount()).stats);
    const result = equippedStats(self.content, self.ownedMember(index), self.weapon_augments[index]);
    return self.withTemporaryStats(index, result);
}

pub fn equippedStats(content: battle.Content, owned: battle.OwnedMember, augment: systems.WeaponAugment) Stats {
    var result = owned.stats;
    if (content.systems) |rules| if (owned.rune) |index| {
        const rune = rules.runes[index];
        if (std.mem.eql(u8, rune.id, "gale")) result.speed = @intCast(@min(9999, @as(u32, result.speed) * 2));
    };
    var total: [8]i16 = @splat(0);
    for (std.enums.values(systems.EquipmentSlot)) |slot| if (owned.loadout.get(slot)) |item| {
        for (content.systems.?.equipment[item].bonuses, 0..) |value, column| total[column] += value;
    };
    if (content.partyProfile(owned.member.id).?.weapon) |weapon| total[6] += @as(i16, @intCast(weapon.powers[owned.weapon_level - 1])) - @as(i16, @intCast(weapon.powers[weapon.initial_level - 1]));
    result.attack = bonus(result.attack, total[0] + total[6]);
    result.skill = bonus(result.skill, total[1] + if (augment.rune == .earth) @as(i16, augment.fragments) * 2 else 0);
    result.defense = bonus(result.defense, total[2] + total[7] + if (augment.rune == .wind) @as(i16, augment.fragments) * 3 else 0);
    result.speed = bonus(result.speed, total[3]);
    result.magic = bonus(result.magic, total[4]);
    result.luck = bonus(result.luck, total[5]);
    return result;
}
pub fn withTemporaryStats(self: *const State, index: usize, value: Stats) Stats {
    var result = value;
    result.skill = bonus(result.skill, self.temporary_stats[index].skill_bonus);
    result.defense = bonus(result.defense, self.temporary_stats[index].defense_bonus);
    return result;
}
pub fn clearTemporaryStats(self: *State) void {
    self.item_impacts = @splat(null);
    self.double_beat_pending = @splat(false);
    self.spark_pending = false;
    self.departed = @splat(false);
    self.departures = @splat(null);
    self.temporary_stats = @splat(.{});
    self.accuracy_reduced = @splat(false);
    self.rune_blocked = @splat(false);
    self.protection = @splat(0);
}
fn bonus(value: u16, amount: i16) u16 {
    return @intCast(std.math.clamp(@as(i32, value) + amount, 0, 9999));
}
pub fn formationSlot(self: *const State, member: usize) usize {
    for (self.formation, 0..) |id, i| if (id == member) return i;
    unreachable;
}
pub fn partyRow(self: *const State, member: usize) Row {
    return if (self.formationSlot(member) < 3) .front else .back;
}
pub fn effectTicks(self: *const State) u16 {
    return self.action_ticks - if (self.active) |effect| effect.started_at else @as(u16, 0);
}
pub fn partyInactive(self: *const State, index: usize) bool {
    std.debug.assert(index < self.partyCount());
    if (self.hp(index) > 0) return false;
    if (self.revivals[index] != null) return false;
    for (self.front_projectiles) |maybe| if (maybe) |shot| if (shot.target == index and !shot.target_released) return false;
    if (self.active) |effect| if (effect.damage_at_impact and self.enemy(effect.actor - self.partyCount()).action_policy == .roc) {
        if (effect.protector == index) return effect.protector_down;
        if (effect.target == index) return effect.target_down;
    };
    return true;
}
pub fn enemyInactive(self: *const State, index: usize) bool {
    if (self.enemy_hp[index] > 0) return false;
    if (self.uniteRecipientLocked(self.partyCount() + index)) return false;
    for (self.party_strikes) |maybe| if (maybe) |strike| if (strike.target == self.partyCount() + index) return strike.target_down;
    return true;
}
pub fn partyStrike(self: *const State) ?PartyStrike {
    if (self.coordinator) |clock| if (clock.current_actor < self.partyCount()) {
        if (self.party_strikes[clock.current_actor]) |strike| if (!strike.owner_released) return strike;
    };
    for (self.party_strikes) |maybe| if (maybe) |strike| if (!strike.owner_released) return strike;
    for (self.party_strikes) |maybe| if (maybe) |strike| return strike;
    return null;
}
pub fn partyTargetDown(self: *const State) bool {
    for (self.party_strikes) |maybe| if (maybe) |strike| if (strike.target_down) return true;
    return false;
}
pub fn enemyRow(self: *const State, target: usize) Row {
    const encounter = self.content.encounters[self.encounter];
    return if (encounter.enemy_rows) |rows| rows[target] else if (target < 3) .front else .back;
}
pub fn weaponRange(self: *const State, member: usize) WeaponRange {
    return self.partyProfile(member).weapon_range orelse .short;
}
pub fn canStartAttack(self: *const State, member: usize) bool {
    return member < self.partyCount() and self.participates(member) and self.unbalanced[member] == 0 and self.asleep[member] == 0;
}
pub fn canAttackTarget(self: *const State, member: usize, target: usize) bool {
    if (!self.canStartAttack(member) or target >= self.enemyCount() or self.enemy_hp[target] == 0) return false;
    if (self.partyProfile(member).motion == null and self.partyProfile(member).attack.len == 0) {
        const packet = (self.unite_actors orelse return false).counterPacket() orelse return false;
        if (packet.rangedAttacker(self.progress.party[member].id) == null) return false;
    }
    return self.weaponRange(member).reaches(self.partyRow(member), self.enemyRow(target));
}
pub fn firstAttackTarget(self: *const State, member: usize) ?usize {
    for (0..self.enemyCount()) |target| if (self.canAttackTarget(member, target)) return target;
    return null;
}
pub fn canFreeWill(self: *const State) bool {
    const art = self.content.world_art orelse return true;
    var queued = self.*;
    queued.chooseFreeWill();
    for (queued.actions[0..self.partyCount()], 0..) |action, member| {
        if (!self.participates(member) or action == null or action.? != .attack) continue;
        const timing = self.partyAttackTiming(member) orelse return false;
        if (self.hasRune(member, "double-beat") and timing.motion == null) return false;
        if (art.attackTracks(self.progress.party[member].id, action.?.attack) == null) return false;
    }
    return true;
}
pub fn chooseFreeWill(self: *State) void {
    self.actions = @splat(null);
    var targets: [6]usize = undefined;
    var count: usize = 0;
    for (0..self.enemyCount()) |target| if (self.enemy_hp[target] > 0) {
        targets[count] = target;
        count += 1;
    };
    var cursor: usize = 0;
    for (self.formation) |member| {
        if (member >= self.partyCount() or self.departed[member]) continue;
        self.actions[member] = .defend;
        var reachable = false;
        for (targets[0..count]) |target| reachable = reachable or self.weaponRange(member).reaches(self.partyRow(member), self.enemyRow(target));
        if (!reachable or self.asleep[member] > 0 or self.unbalanced[member] > 0) continue;
        // The source cursor advances even for KO owners; range filtering precedes its wrap test.
        var candidate = cursor + 1;
        while (true) {
            if (candidate >= count) candidate = 0;
            const target = targets[candidate];
            if (self.weaponRange(member).reaches(self.partyRow(member), self.enemyRow(target))) {
                self.actions[member] = .{ .attack = target };
                break;
            }
            candidate += 1;
            if (candidate == cursor) break;
        }
        cursor = (cursor + 1) % count;
    }
}
pub fn promoteRearMembers(self: *State) void {
    for (0..self.partyCount()) |fallen| {
        if (self.participates(fallen) or self.knockout_pending[fallen] or self.revivals[fallen] != null or self.partyRow(fallen) != .front) continue;
        for (0..self.partyCount()) |replacement| {
            if (!self.participates(replacement) or self.partyRow(replacement) != .back or self.coordinatorLocked(replacement)) continue;
            if (self.content.world_art != null and self.content.world_art.?.c_tracks != null) {
                self.formation_shifts[fallen] = .{ .from_slot = self.formationSlot(fallen), .started_at = self.presentation_tick -% 1 };
                self.formation_shifts[replacement] = .{ .from_slot = self.formationSlot(replacement), .started_at = self.presentation_tick -% 1 };
            } else if (self.content.world_art == null and self.sourceRounds() and (self.sharedPartyMelee() or (types_mod.battleSchemaVersion(self.content.schema) orelse 0) == 32 or for (self.content.enemies) |enemy| {
                if (enemy.action_policy == .source_projectile) break true;
            } else false)) {
                self.formation_shifts[fallen] = .{ .from_slot = self.formationSlot(fallen), .started_at = self.camera_ticks -% 1 };
                self.formation_shifts[replacement] = .{ .from_slot = self.formationSlot(replacement), .started_at = self.camera_ticks -% 1 };
            }
            std.mem.swap(u8, &self.formation[self.formationSlot(fallen)], &self.formation[self.formationSlot(replacement)]);
            break;
        }
    }
}
pub fn swapFormation(self: *State, first: usize, second: usize) !void {
    if (first >= self.partyCount() or second >= self.partyCount()) return error.InvalidMember;
    std.mem.swap(u8, &self.formation[first], &self.formation[second]);
    if (self.phase == .command) self.choose(self.actor);
}
pub fn weaponName(self: *const State, member: usize) []const u8 {
    const weapon = self.partyProfile(member).weapon orelse return "Weapon";
    return weapon.names[self.weapon_levels[member] - 1];
}
pub fn sharpenPrice(self: *const State, member: usize, limit: u8) !u32 {
    if (member >= self.partyCount() or limit == 0 or limit > 16) return error.InvalidMember;
    const weapon = self.partyProfile(member).weapon orelse return error.InvalidWeapon;
    const level = self.weapon_levels[member];
    if (level == 0 or level > 16) return error.InvalidWeapon;
    if (level >= limit) return error.WeaponLimit;
    return weapon.upgrade_costs[level];
}
pub fn sharpen(self: *State, member: usize, limit: u8, money: *u32) !void {
    const price = try self.sharpenPrice(member, limit);
    if (money.* < price) return error.InsufficientFunds;
    self.weapon_levels[member] += 1;
    money.* -= price;
}
