const std = @import("std");
const field = @import("field");
const battle_systems = @import("battle_systems");
const technique_systems = battle_systems.techniques;
const presentation = @import("battle_presentation.zig");
const systems = @import("battle_rules");
const battle = @import("battle.zig");
const types_mod = @import("battle_types.zig");
const State = battle.State;
const Member = types_mod.Member;
const Frame = types_mod.Frame;
const Input = types_mod.Input;

pub fn headEquipment(self: State) [6]?usize {
    var result: [6]?usize = @splat(null);
    for (self.progress.party, 0..) |member, i| result[i] = member.loadout.head;
    return result;
}
pub fn equip(self: *State, member: usize, item: ?usize) !void {
    try self.equipSlot(member, .head, item);
}
pub fn equipSlot(self: *State, member: usize, slot: systems.EquipmentSlot, item: ?usize) !void {
    const rules = self.content.systems orelse return error.InvalidEquipment;
    if (member >= self.partyCount()) return error.InvalidMember;
    if (item) |id| if (id >= rules.equipment.len or !rules.equipment[id].allows(self.partyProfile(member).id, slot)) return error.InvalidEquipment;
    self.progress.party[member].loadout.set(slot, item);
    refreshMagicCapacity(self, member);
}

pub fn refreshMagicCapacity(self: *State, member: usize) void {
    self.progress.party[member].refreshRuneCapacity(self.content.systems.?);
}
pub fn rune(self: *const State, member: usize) ?systems.Rune {
    const rules = self.content.systems orelse return null;
    var result = if (self.progress.party[member].rune) |i| rules.runes[i] else return null;
    if (std.mem.eql(u8, result.id, "soul_eater")) if (self.progress.story.scenario) |story| {
        for (&result.spells, 0..) |*spell, tier| if (tier >= story.soul_eater_spell_slots) {
            spell.* = null;
            result.spell_names[tier] = "";
        };
    };
    return result;
}
pub fn checkRuneAttachment(self: State, member: usize, owner: usize, slot: usize) !usize {
    if (member >= self.partyCount() or owner >= self.partyCount()) return error.InvalidRune;
    const rules = self.content.characterRules();
    try rules.checkRuneTarget(self.progress.party[member]);
    if (self.progress.party[member].rune != null) return error.RuneOccupied;
    try self.progress.validate();
    return rules.attachmentRune(self.progress.party[member].id, self.progress.party[owner].inventory, slot);
}
pub fn attachRune(self: *State, member: usize, owner: usize, slot: usize) !void {
    const index = try self.checkRuneAttachment(member, owner, slot);
    self.progress.party[member].rune = index;
    self.progress.party[owner].inventory.remove(slot);
}
pub fn detachRune(self: *State, member: usize) !void {
    if (member >= self.partyCount()) return error.InvalidRune;
    const rules = self.content.characterRules();
    try rules.checkRuneTarget(self.progress.party[member]);
    try self.progress.validate();
    try rules.detachRune(&self.progress.party[member]);
}
pub fn hasRune(self: *const State, member: usize, id: []const u8) bool {
    const owned = self.rune(member) orelse return false;
    return std.mem.eql(u8, owned.id, id);
}
pub fn runeHint(self: *const State, member: usize) []const u8 {
    if (self.actor_conditions[member].rune_blocked) return "Runes are blocked by a status condition.";
    if (self.hasRune(member, "double-beat")) return "Passive: follow-up physical attacks.";
    if (self.hasRune(member, "spark")) return "Passive: allies follow an ordinary attack.";
    if (self.hasRune(member, "turtle")) return "Passive: blocks new status changes.";
    if (self.hasRune(member, "phero")) return "Passive: eligible allies may protect you at low HP.";
    if (self.hasRune(member, "hazy")) return "Passive: halves enemy hit chance.";
    if (self.hasRune(member, "killer")) return "Passive: more triple-damage strikes.";
    if (self.hasRune(member, "gale")) return "Passive: doubles base SPD.";
    if (self.hasRune(member, "sunbeam")) return "Passive: restores5 HP each round.";
    if (self.hasRune(member, "fortune")) return "Passive: doubles this member's EXP.";
    if (self.hasRune(member, "prosperity")) return "Passive: doubles battle money.";
    if (self.physicalRune(member) != null) return "Physical technique; recover next turn.";
    if (self.canPhysicalRune(member)) return "Physical technique.";
    if (self.hasRune(member, "boar") or self.hasRune(member, "clone")) return "Physical technique unavailable.";
    const owned = self.rune(member) orelse return "No rune equipped.";
    for (owned.spells) |slot| if (slot != null) return "Spells require a matching usable charge.";
    return "This rune's effect is unavailable.";
}
pub fn spellTier(self: *const State, member: usize, spell: usize) ?u2 {
    const owned = self.rune(member) orelse return null;
    for (owned.spells, 0..) |slot, tier| if (slot != null and slot.? == spell) return @intCast(tier);
    return null;
}
pub fn canCast(self: *const State, member: usize, spell: usize) bool {
    const rules = self.content.systems orelse return false;
    if (member >= self.partyCount() or spell >= rules.spells.len) return false;
    if (rules.spells[spell].kind == .source_rule and self.integration == null) return false;
    const tier = self.spellTier(member, spell) orelse return false;
    return self.canStartAttack(member) and !self.actor_conditions[member].rune_blocked and self.progress.party[member].rune_charges[tier] > 0;
}
pub fn physicalRune(self: *const State, member: usize) ?systems.PhysicalRune {
    const owned = self.rune(member) orelse return null;
    return owned.physical;
}
pub fn canPhysicalRune(self: *const State, member: usize) bool {
    if (!self.canStartAttack(member) or self.actor_conditions[member].rune_blocked) return false;
    if (self.unite_actors) |bundle| if (bundle.physicalPacket()) |packet| {
        const technique = technique_systems.physical.techniqueForRune(self.runeByteFor(member) orelse return false) orelse return false;
        for (packet.find(technique).?.members) |id| if (std.mem.eql(u8, id, self.progress.party[member].id)) return true;
        return false;
    };
    if (self.partyProfile(member).motion == null and self.partyProfile(member).attack.len == 0) return false;
    if (self.physicalRune(member) != null) return true;
    // Battle techniques add Shrike/Falcon/Trick, which the shared systems catalogue
    // does not list as physical techniques; the source rune byte is the
    // authority once the integration host is attached.
    if (self.integration != null) {
        const byte = self.runeByteFor(member) orelse return false;
        const technique = technique_systems.physical.techniqueForRune(byte) orelse return false;
        return technique_systems.physical.info(technique).status != .unsupported;
    }
    return false;
}
pub fn canUseRune(self: *const State, member: usize) bool {
    return self.canPhysicalRune(member) or self.hasMagic(member);
}
pub fn hasMagic(self: *const State, member: usize) bool {
    const owned = self.rune(member) orelse return false;
    for (owned.spells) |slot| if (slot) |spell| if (self.canCast(member, spell)) return true;
    return false;
}
pub fn refillMagic(self: *State, member: usize) void {
    self.progress.party[member].refillRuneCharges(self.content.systems.?);
}
pub fn uniteDefinition(self: *const State, actor: usize) ?systems.Unite {
    const rules = self.content.systems orelse return null;
    const id = self.partyProfile(actor).id;
    for (0..rules.additional_unites.len + 1) |i| {
        const candidate = if (i == 0) rules.unite else rules.additional_unites[i - 1];
        if (std.mem.eql(u8, id, candidate.members[0]) or std.mem.eql(u8, id, candidate.members[1])) return candidate;
    }
    return null;
}
pub fn uniteName(self: *const State, actor: usize) []const u8 {
    if (self.integrationHost()) |host| {
        if (self.uniteBoundaryFor(actor)) |boundary| return host.uniteCatalogue().recordAt(boundary.record_index).?.name;
        for (0..self.enemyCount()) |target| {
            if (self.unitePlan(actor, target)) |result| switch (result) {
                .boundary => |boundary| return host.uniteCatalogue().recordAt(boundary.record_index).?.name,
                .refusal => {},
            };
        }
    }
    return if (self.uniteDefinition(actor)) |definition| definition.name else "Unite";
}

pub fn unitePartner(self: *const State, actor: usize) ?usize {
    const definition = self.uniteDefinition(actor) orelse return null;
    const id = self.partyProfile(actor).id;
    const other = if (std.mem.eql(u8, id, definition.members[0])) definition.members[1] else definition.members[0];
    for (self.progress.party, 0..) |member, i| if (std.mem.eql(u8, member.id, other) and self.canStartAttack(i) and member.status != .poisoned) return i;
    return null;
}
pub fn actionMotion(self: *const State, member: usize) ?presentation.Motion {
    if (self.uniteReturnFor(member) != null) return if (self.uniteTrack(member)) |track| track.motion else null;
    if (member >= self.partyCount()) return if (self.active != null and self.active.?.enemy_special) null else self.enemy(member - self.partyCount()).motion;
    const profile = self.partyProfile(member);
    if (self.activeUniteMember(member)) if (self.uniteTrack(member)) |track| return track.motion;
    return profile.motion;
}
pub fn attackFrames(self: *const State, member: usize) []const Frame {
    const profile = if (member < self.partyCount()) self.partyProfile(member) else self.enemy(member - self.partyCount());
    if (self.uniteReturnFor(member) != null or self.activeUniteMember(member)) if (self.uniteTrack(member)) |track| return track.attack;
    return profile.attack;
}
pub fn canUnite(self: *const State, actor: usize) bool {
    if (self.integration != null) return self.canUniteIntegrated(actor);
    const partner = self.unitePartner(actor) orelse return false;
    return self.canStartAttack(actor) and self.progress.party[actor].status != .poisoned and (self.actions[partner] == null or (self.actions[partner].? == .assist and self.actions[partner].?.assist == actor));
}
pub fn roll(self: *State) u15 {
    if (self.replay_draws) |draws| return draws.next() catch {
        // Accepting sentinel terminates target scans; tickReplay discards the entire update.
        self.replay_exhausted = true;
        return 32767;
    };
    return self.random.random().int(u15);
}
pub fn tickReplay(self: *State, input: Input, draws: *systems.Draws) !void {
    if (self.replay_draws != null or self.partyCount() > 6 or !draws.valid() or input.restart) return error.InvalidBattleReplay;
    const before = self.*;
    const saved_draws = draws.*;
    var members: [6]Member = undefined;
    @memcpy(members[0..self.partyCount()], self.progress.party);
    self.replay_draws = draws;
    self.replay_exhausted = false;
    self.replay_unsupported = null;
    self.tick(input);
    self.replay_draws = null;
    if (self.replay_exhausted or self.replay_unsupported != null) {
        const failure = if (self.replay_exhausted) error.RandomInputExhausted else switch (self.replay_unsupported.?) {
            .missing_protection => error.MissingBattleProtectionData,
            .coordinator_action => error.UnsupportedCoordinatorAction,
            .phero_fallback => error.UnsupportedPheroFallback,
            .enemy_policy => error.UnsupportedWorldEnemyPolicy,
        };
        self.* = before;
        @memcpy(self.progress.party, members[0..self.partyCount()]);
        draws.* = saved_draws;
        return failure;
    }
}
pub fn uniteScreenOffset(self: *const State, member: usize) [2]i8 {
    if (self.unite_vm.pose(member) != null) return self.unite_vm.actors[member].screen_offset;
    const retained = if (self.content.world_art == null and member < self.actor_transforms.len) self.actor_transforms[member].screen_offset else [2]i8{ 0, 0 };
    if (member >= self.partyCount() or (!self.activeUniteMember(member) and self.uniteReturnFor(member) == null) or self.uniteMemberWaiting(member)) return retained;
    const track = self.uniteTrack(member) orelse return retained;
    const elapsed = self.animationTick(member);
    const target = if (self.uniteReturnFor(member)) |tail| tail.target else self.active.?.target;
    const profile = if (target < self.partyCount()) self.partyProfile(target) else self.enemy(target - self.partyCount());
    const anchor = profile.effect_offset orelse .{ 0, 0 };
    var current: [2]i8 = retained;
    for (track.screen_offsets) |change| {
        if (elapsed < change.start) break;
        const count = @min(change.updates, elapsed - change.start + 1);
        for (0..count) |step| for (0..2) |axis| {
            const destination: i32 = @as(i32, change.value[axis]) + (if (change.target) @as(i32, anchor[axis]) else 0);
            const remaining: i32 = @intCast(change.updates - step);
            current[axis] = @truncate(@as(i32, current[axis]) + @divTrunc(destination - current[axis], remaining));
        };
        if (count < change.updates) break;
    }
    return current;
}
pub fn advanceUniteTrails(self: *State, previous: [6]presentation.ScreenPoint) void {
    for (&self.unite_trails, 0..) |*ring, member| {
        ring.visible = false;
        if (self.unite_vm.ownsActor(member)) {
            if (self.unite_vm.actors[member].blue_trail) |trail| {
                ring.* = .{ .next = trail.next, .initialized = true, .visible = trail.visible };
                for (&ring.points, trail.points) |*point, captured| point.* = .{ .x = captured[0], .y = captured[1], .depth = trail.depth };
            } else ring.initialized = false;
            continue;
        }
        if (member >= self.partyCount() or !self.activeUniteMember(member) or self.uniteMemberWaiting(member)) {
            ring.initialized = false;
            continue;
        }
        const track = self.uniteTrack(member) orelse continue;
        const trail = track.trail orelse continue;
        const elapsed = self.animationTick(member);
        if (elapsed == trail.start) {
            ring.* = .{ .points = @splat(previous[member]), .initialized = true };
        } else if (elapsed > trail.start and elapsed < trail.stop and ring.initialized) {
            ring.points[ring.next] = previous[member];
            ring.next +%= 1;
            ring.visible = true;
        } else if (elapsed < trail.start or elapsed > trail.stop) ring.initialized = false;
    }
}
pub fn enemySourceSlot(self: *const State, index: usize) usize {
    return if (self.content.encounters[self.encounter].source_slots) |slots| slots[index] else index;
}
pub fn firstLiving(self: *const State, party: bool) ?usize {
    const start: usize = if (party) 0 else self.partyCount();
    const end = if (party) self.partyCount() else self.partyCount() + self.enemyCount();
    for (start..end) |index| if (self.participates(index)) return index;
    return null;
}
