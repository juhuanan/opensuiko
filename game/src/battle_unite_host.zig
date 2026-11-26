const std = @import("std");
const battle_systems = @import("battle_systems");
const technique_systems = battle_systems.techniques;
const unite_systems = battle_systems.unite;
const layout = @import("battle_layout.zig");
const spell_scene = @import("battle_spell_scene.zig");
const systems = @import("battle_rules");
const battle = @import("battle.zig");
const State = battle.State;

pub fn characterId(self: *const State, member: usize) ?u8 {
    const host = self.integrationHost() orelse return null;
    if (member >= self.partyCount()) return null;
    return host.characterId(self.progress.party[member].id);
}

/// Join by stable rune key: party composition filters and compacts the catalogue.
const rune_keys = [_][]const u8{ "fire", "water", "wind", "lightning", "earth", "resurrection", "boar", "shrike", "falcon", "hate", "trick", "clone", "double-beat", "killer", "counter", "spark", "hazy", "gale", "sunbeam", "holy", "true_holy", "fortune", "prosperity", "champion's", "turtle", "phero", "rage", "flowing", "cyclone", "mother_earth", "thunder" };

pub fn runeByteFor(self: *const State, member: usize) ?u8 {
    const index = self.progress.party[member].rune orelse return null;
    const owned = self.content.systems.?.runes[index];
    if (std.mem.eql(u8, owned.id, "masked_rune_32")) return 32;
    if (std.mem.eql(u8, owned.id, "soul_eater")) return 1;
    for (rune_keys, 0..) |key, source_index| {
        if (std.mem.eql(u8, owned.id, key)) return technique_systems.physical.runeByteFromCatalogue(@intCast(source_index));
    }
    return null;
}

// -----------------------------------------------------------------------
// Unite boundary over the existing action coordinator.
// -----------------------------------------------------------------------

pub const UniteContext = struct {
    state: *State,
    boundary: *unite_systems.Boundary,
    leader: usize,
    target_enemy: usize,
};

fn uniteWriteSlot(context: *anyopaque, slot: usize, write: unite_systems.CommandWrite) void {
    const ctx: *UniteContext = @ptrCast(@alignCast(context));
    if (slot >= ctx.state.partyCount()) return;
    if (write.command == .unite) {
        if (slot == ctx.leader) {
            ctx.state.actions[slot] = .{ .unite = ctx.target_enemy };
        } else {
            ctx.state.actions[slot] = .{ .assist = ctx.leader };
        }
        // shortcut: timed playback supplies flags here; live scripts clear them at startup.
        ctx.state.unite_flags[slot] = (unite_systems.ActorFlags{ .hit_ready = true, .return_ready = true }).toMask();
    } else {
        ctx.state.actions[slot] = null;
    }
}

fn uniteWriteStatus(context: *anyopaque, slot: usize, status_flags: unite_systems.StatusFlags, counter: u8) void {
    const ctx: *UniteContext = @ptrCast(@alignCast(context));
    if (slot >= ctx.state.partyCount()) return;
    if (status_flags.recovering) {
        if (ctx.state.unite_vm.owns(slot) and ctx.state.unite_vm.members[slot].?.recovery_applied) return;
        ctx.state.requestUniteRecovery(slot, counter +| 1) catch |err| switch (err) {
            error.RandomInputExhausted => {}, // tickReplay restores the failed update and draw cursor.
            else => ctx.state.replay_unsupported = .coordinator_action,
        };
    } else {
        ctx.state.unbalanced[slot] = 0;
    }
}

fn uniteWriteFlags(context: *anyopaque, slot: usize, flags: unite_systems.ActorFlags) void {
    const ctx: *UniteContext = @ptrCast(@alignCast(context));
    const mask = flags.toMask();
    if (slot < ctx.state.unite_flags.len) ctx.state.unite_flags[slot] = mask;
    if (ctx.state.unite_vm.owns(slot)) ctx.state.unite_vm.actors[slot].signals = mask;
}

fn uniteApplyDamage(context: *anyopaque, target: unite_systems.Target, amount: u32) void {
    const ctx: *UniteContext = @ptrCast(@alignCast(context));
    const index = target.toCombatantIndex(ctx.state.partyCount()) orelse return;
    if (index >= ctx.state.partyCount() + ctx.state.enemyCount()) return;
    const before_hp = ctx.state.hp(index);
    const applied = if (ctx.state.actor_conditions[index].protection_rounds > 0) 0 else amount;
    const origin = ctx.state.uniteReactionOriginQ12(index);
    if (ctx.state.active) |*effect| {
        effect.affected |= @as(u16, 1) << @intCast(index);
        effect.amounts[index] = applied;
    }
    if (index < ctx.state.partyCount()) {
        const member = &ctx.state.progress.party[index];
        member.hp = @intCast(@as(u32, member.hp) -| applied);
        ctx.state.markPartyKnockout(index);
    } else {
        const enemy_index = index - ctx.state.partyCount();
        ctx.state.enemy_hp[enemy_index] = @intCast(@as(u32, before_hp) -| applied);
        // shortcut: use the shared enemy KO tail until per-Unite death choreography is qualified.
        if (before_hp > 0 and ctx.state.enemy_hp[enemy_index] == 0) {
            if (ctx.state.uniteReactionPose(index)) |pose| if (pose.knockout) |ko| {
                ctx.state.unite_reactions[index] = .{ .record = ctx.boundary.record_index, .started_at = ctx.state.camera_ticks, .origin_q12 = origin, .home_q12 = origin, .knockout_ticks = ko.duration };
                return;
            };
            ctx.state.unite_reactions[index] = null;
            return;
        }
    }
    const damage_reaction = if (ctx.state.unite_actors) |bundle| blk: {
        const binding = bundle.find(ctx.boundary.record_index).?;
        break :blk binding.damage_reaction and (binding.controller == null or binding.controller.?.mode == .owner_clock);
    } else true;
    const martial = if (ctx.state.martial_queue) |queue| queue.owner == ctx.leader else false;
    if (damage_reaction and !martial) ctx.state.startUniteReaction(index, ctx.boundary.record_index, 0, origin);
}
pub fn uniteReactionOriginQ12(self: *const State, index: usize) [3]i32 {
    if (self.unite_vm.ownsActor(index)) if (self.unite_vm.position(index)) |position| return position;
    if (self.unite_reactions[index]) |instance| if (self.uniteReactionProgram(index)) |reaction| {
        const age = self.camera_ticks - instance.started_at;
        if (age == 0) return instance.origin_q12;
        const absolute_tail = reaction.motions.len != 0 and reaction.motions[reaction.motions.len - 1].absolute;
        if ((self.unite_vm.idle[index] == null or age < reaction.duration) and (age - 1 < reaction.duration or absolute_tail or reaction.retain_lock)) return spell_scene.unitePosition(reaction, instance.origin_q12, instance.home_q12, age - 1);
    };
    if (self.unite_vm.position(index)) |position| return position;
    const origin = layout.worldPosition(self, index);
    return .{ @intFromFloat(@round(origin.x * 4096)), @intFromFloat(@round(origin.y * 4096)), @intFromFloat(@round(origin.z * 4096)) };
}
pub fn startUniteReaction(self: *State, index: usize, record: u8, variant: u8, origin_q12: [3]i32) void {
    if (self.unite_reactions[index]) |instance| if (instance.knockout_ticks != 0) return;
    if ((self.hasLiveUniteActors() or self.hasUniteTracks()) and self.hasUniteReactionBinding(record, variant, index) and self.hp(index) > 0) {
        const home = layout.homePosition(self, index);
        self.unite_reactions[index] = .{ .record = record, .variant = variant, .started_at = self.camera_ticks, .origin_q12 = origin_q12, .home_q12 = .{ @intFromFloat(@round(home.x * 4096)), @intFromFloat(@round(home.y * 4096)), @intFromFloat(@round(home.z * 4096)) } };
        self.applyUniteReactionSignals(index, 0);
    } else self.unite_reactions[index] = null;
}

fn unitePhysical(context: *anyopaque, slot: usize, target: unite_systems.Target, draws: *systems.Draws) anyerror!u32 {
    const ctx: *UniteContext = @ptrCast(@alignCast(context));
    const index = target.toCombatantIndex(ctx.state.partyCount()) orelse return error.InvalidTarget;
    if (index < ctx.state.partyCount() or index >= ctx.state.partyCount() + ctx.state.enemyCount()) return error.InvalidTarget;
    return ctx.state.resolvePhysicalDamage(slot, index, try draws.next(), false);
}

fn uniteHitReady(context: *anyopaque, slot: usize) bool {
    const ctx: *UniteContext = @ptrCast(@alignCast(context));
    if (ctx.state.unite_vm.owns(slot)) return ctx.state.unite_vm.hitReady(slot);
    return slot < ctx.state.unite_flags.len and unite_systems.ActorFlags.fromMask(ctx.state.unite_flags[slot]).hit_ready;
}

pub fn uniteHost(ctx: *UniteContext) unite_systems.Host {
    return .{
        .context = ctx,
        .write_slot = uniteWriteSlot,
        .write_status = uniteWriteStatus,
        .write_flags = uniteWriteFlags,
        .apply_damage = uniteApplyDamage,
        .physical = unitePhysical,
        .hit_ready = uniteHitReady,
    };
}

pub fn uniteView(self: *const State, party: *[6]unite_systems.Slot, enemies: *[6]unite_systems.Slot) unite_systems.View {
    for (0..self.partyCount()) |index| {
        const member = self.progress.party[index];
        const slot_status: unite_systems.StatusFlags = .{
            .poisoned = member.status == .poisoned,
            .asleep = self.actor_conditions[index].sleep_turns > 0,
            .recovering = self.unbalanced[index] > 0,
        };
        party[index] = .{
            .character_id = self.characterId(index) orelse 0,
            .active = self.participates(index),
            .status = slot_status,
            .hp = @intCast(@min(member.hp, 9999)),
            .status_byte = 0,
            .available = self.actions[index] == null,
            .command = if (self.actions[index]) |action| switch (action) {
                .unite => .unite,
                else => .attack,
            } else .none,
            .unite_record = null,
            .target = unite_systems.Target.fromSourceIndex(self.partyCount(), self.last_targets[index]),
            .recovery_counter = self.unbalanced[index] -| 1,
            .actor_flags = unite_systems.ActorFlags.fromMask(self.unite_flags[index]),
        };
    }
    for (0..self.enemyCount()) |index| {
        enemies[index] = .{
            .character_id = 0,
            .active = self.enemy_hp[index] > 0,
            .status = .{},
            .hp = @intCast(self.enemy_hp[index]),
            .status_byte = 0,
            .available = true,
            .command = .none,
            .unite_record = null,
            .target = .none,
            .recovery_counter = 0,
            .actor_flags = .{},
        };
    }
    return .{ .party = party[0..self.partyCount()], .enemies = enemies[0..self.enemyCount()] };
}

/// Build the pending boundary for the first catalogue record that contains
/// the actor and whose whole member list is available.  Pure: plan never
/// writes and never draws.
pub fn unitePlan(self: *const State, actor: usize, target_enemy: usize) ?unite_systems.PlanResult {
    const host = self.integrationHost() orelse return null;
    const catalogue = host.uniteCatalogue();
    const actor_id = self.characterId(actor) orelse return null;
    if (actor >= self.partyCount() or target_enemy >= self.enemyCount()) return null;
    var party_slots: [6]unite_systems.Slot = undefined;
    var enemy_slots: [6]unite_systems.Slot = undefined;
    const view = self.uniteView(&party_slots, &enemy_slots);
    var containing: [unite_systems.catalogue.max_records]usize = undefined;
    const count = catalogue.containing(actor_id, &containing);
    if (count == 0) return null;
    for (containing[0..count]) |record_index| {
        if (self.selected_unites[actor]) |selected| if (record_index != selected) continue;
        const record = catalogue.recordAt(@intCast(record_index)) orelse continue;
        if (!record.proven()) continue;
        const result = unite_systems.plan(catalogue, view, .{
            .actor = actor,
            .record = @intCast(record_index),
            .target = .{ .enemy = target_enemy },
        });
        switch (result) {
            .boundary => return result,
            .refusal => |refusal| switch (refusal) {
                .effect_family_blocked, .missing_member => continue,
                else => return result,
            },
        }
    }
    return .{ .refusal = .effect_family_blocked };
}

pub fn selectUnite(self: *State, actor: usize, record: u8) bool {
    if (actor >= self.partyCount()) return false;
    var candidate = self.*;
    candidate.selected_unites[actor] = record;
    if (!candidate.canUniteIntegrated(actor)) return false;
    self.selected_unites[actor] = record;
    return true;
}

pub fn cycleUnite(self: *State, actor: usize, backwards: bool) void {
    if (actor >= self.partyCount()) return;
    var choices: [unite_systems.catalogue.max_records]u8 = undefined;
    var count: usize = 0;
    var current = self.selected_unites[actor];
    if (current == null) for (0..self.enemyCount()) |target| {
        if (self.unitePlan(actor, target)) |result| switch (result) {
            .boundary => |boundary| {
                current = boundary.record_index;
                break;
            },
            .refusal => {},
        };
    };
    var selected: usize = 0;
    for (0..unite_systems.catalogue.max_records) |record| {
        var candidate = self.*;
        if (candidate.selectUnite(actor, @intCast(record))) {
            choices[count] = @intCast(record);
            if (current == @as(u8, @intCast(record))) selected = count;
            count += 1;
        }
    }
    if (count == 0) return;
    self.selected_unites[actor] = choices[(selected + if (backwards) count - 1 else 1) % count];
}

pub fn canUniteIntegrated(self: *const State, actor: usize) bool {
    // The target picker runs after the command; membership and reservation
    // are the selectability facts.  Any living enemy slot is enough for an
    // individual record, while a bypass record needs a prior target.
    var candidate: usize = 0;
    while (candidate < self.enemyCount()) : (candidate += 1) {
        if (self.enemy_hp[candidate] == 0) continue;
        if (self.unitePlan(actor, candidate)) |result| switch (result) {
            .boundary => return true,
            .refusal => {},
        };
    }
    for (0..self.enemyCount()) |index| if (self.unitePlan(actor, index)) |result| switch (result) {
        .boundary => return true,
        .refusal => {},
    };
    return false;
}

pub fn uniteBoundaryFor(self: *const State, actor: usize) ?*const unite_systems.Boundary {
    if (actor >= self.unite_boundaries.len) return null;
    if (self.unite_boundaries[actor]) |*boundary| return boundary;
    return null;
}

pub fn activeUniteBoundary(self: *const State) ?*const unite_systems.Boundary {
    const effect = self.active orelse return null;
    if (effect.kind != .unite) return null;
    return self.uniteBoundaryFor(effect.actor);
}

pub fn clearUniteFlags(self: *State, boundary: *const unite_systems.Boundary) void {
    for (boundary.participantsSlice()) |participant| {
        if (participant < self.unite_flags.len) self.unite_flags[participant] = 0;
    }
}

/// Reject before initialization without undoing the other participants' queued turns.
pub fn discardUnite(self: *State, actor: usize) void {
    const boundary = self.uniteBoundaryFor(actor) orelse return;
    for (boundary.participantsSlice(), 0..) |member, index| self.unite_flags[member] = boundary.prior[index].actor_flags.toMask();
    self.unite_boundaries[actor] = null;
}

pub fn releaseUniteFor(self: *State, actor: usize) void {
    for (&self.unite_boundaries, 0..) |*maybe, owner| {
        const boundary = if (maybe.*) |*value| value else continue;
        var owns = false;
        for (boundary.participantsSlice()) |participant| if (participant == actor) {
            owns = true;
            break;
        };
        if (!owns) continue;
        var ctx = UniteContext{ .state = self, .boundary = boundary, .leader = 0, .target_enemy = 0 };
        boundary.undo(uniteHost(&ctx));
        self.clearUniteFlags(boundary);
        for (&self.unite_vm.auxiliary, 0..) |*child, index| if (child.*) |value| {
            const parent = value.owner orelse continue;
            if (parent < self.unite_vm.members.len) if (self.unite_vm.members[parent]) |member| {
                if (member.leader == owner) {
                    child.* = null;
                    self.unite_vm.auxiliary_bindings[index] = null;
                }
            };
        };
        for (&self.unite_vm.members, 0..) |*member, slot| if (member.*) |value| {
            if (value.leader != owner) continue;
            member.* = null;
            self.unite_returns[slot] = null;
            self.unite_trails[slot].visible = false;
        };
        if (self.unite_scene) |scene| if (scene.owner == owner) {
            self.unite_scene = null;
            for (self.partyCount()..self.partyCount() + self.enemyCount()) |target| {
                self.actor_transforms[target].node_angles[0] = 0;
                self.actor_transforms[target].node_angles[2] = 0;
            }
        };
        if (self.trick_wave) |wave| {
            if (wave.owner == owner) self.trick_wave = null;
        }
        if (self.martial_queue) |queue| if (queue.owner == owner) {
            self.martial_queue = null;
        };
        maybe.* = null;
        return;
    }
}

pub fn hasUniteSequence(self: *const State) bool {
    const boundary = self.activeUniteBoundary() orelse return false;
    return boundary.sequence != null;
}

fn resolveLiveUniteSequence(self: *State, boundary: *unite_systems.Boundary) void {
    const host = self.integrationHost() orelse return;
    const bundle = self.unite_actors.?;
    const queue = &boundary.sequence.?;
    // shortcut: rotating a live Master–Pupil body needs the rotated packet footprint.
    for (boundary.participantsSlice()) |member| if (self.unite_vm.owns(member) and
        !std.mem.eql(i16, &self.actor_transforms[member].node_angles, &.{ 0, 0, 0 }))
    {
        self.replay_unsupported = .coordinator_action;
        return;
    };
    for (boundary.participantsSlice(), 0..) |member, ordinal| {
        if (!self.unite_vm.signalReady(member, 16)) continue;
        const enemy: ?usize = for (queue.pending, 0..) |pending, index| {
            if (pending) break index;
        } else null;
        if (enemy) |index| {
            queue.pending[index] = false;
            queue.targets[ordinal] = index;
        } else {
            queue.targets[ordinal] = null;
            queue.return_at[ordinal] = self.effectTicks();
        }
        self.unite_vm.sequenceDispatch(bundle, member, if (enemy) |index| @intCast(self.partyCount() + index) else null) catch {
            self.replay_unsupported = .coordinator_action;
            return;
        };
        self.unite_flags[member] &= ~@as(u16, 16);
    }
    for (boundary.participantsSlice(), 0..) |member, ordinal| {
        if (!self.unite_vm.signalReady(member, 2)) continue;
        const target = queue.targets[ordinal] orelse {
            self.replay_unsupported = .coordinator_action;
            return;
        };
        var party_slots: [6]unite_systems.Slot = undefined;
        var enemy_slots: [6]unite_systems.Slot = undefined;
        const view = self.uniteView(&party_slots, &enemy_slots);
        var ctx = UniteContext{ .state = self, .boundary = boundary, .leader = boundary.command_owner, .target_enemy = 0 };
        var empty_draws = systems.Draws{};
        const draws = self.replay_draws orelse &empty_draws;
        switch (unite_systems.impactSequenceTarget(boundary, host.uniteCatalogue(), view, uniteHost(&ctx), draws, .{ .enemy = target })) {
            .applied => |amount| {
                boundary.amount +|= amount;
                boundary.stage = .impacted;
                self.active.?.amount = amount;
            },
            .skipped => {},
            .failed => |failure| {
                switch (failure) {
                    .random => |err| if (err == error.RandomInputExhausted) {
                        self.replay_exhausted = true;
                    } else {
                        self.replay_unsupported = .coordinator_action;
                    },
                    .refusal => self.replay_unsupported = .coordinator_action,
                }
                return;
            },
        }
        self.unite_flags[member] &= ~@as(u16, 2);
        self.unite_vm.actors[member].signals &= ~@as(u16, 2);
    }
    if (queue.finish_at == null) {
        var last: u16 = 0;
        for (queue.return_at[0..boundary.count]) |value| {
            last = @max(last, value orelse return);
        }
        const record = host.uniteCatalogue().recordAt(boundary.record_index).?;
        queue.finish_at = last +| record.sequence.?.finish_delay;
    }
}

pub fn beginTrickWave(self: *State, owner: usize, heights: battle.unite_trick.Heights) !void {
    const boundary = self.uniteBoundaryFor(owner) orelse return error.InvalidUniteSceneBinding;
    if (boundary.record_index != 14 or boundary.count != 2 or boundary.stage != .committed or (self.trick_wave != null and !self.trick_wave.?.wave.finished)) return error.InvalidUniteSceneBinding;
    self.trick_wave = .{ .owner = owner, .wave = try battle.unite_trick.State.init(heights) };
}
fn resolveTrickWave(self: *State, boundary: *unite_systems.Boundary) void {
    const playback = if (self.trick_wave) |*value| value else return;
    if (playback.owner != boundary.command_owner or playback.updated_at == self.camera_ticks) return;
    playback.updated_at = self.camera_ticks;
    const trigger = boundary.participantsSlice()[1];
    var targets: [6]?i32 = @splat(null);
    for (0..self.enemyCount()) |enemy| targets[enemy] = self.uniteReactionOriginQ12(self.partyCount() + enemy)[0];
    const events = playback.wave.advance(self.unite_flags[trigger] & 16 != 0, targets);
    if (events.sound) |id| {
        self.unite_vm.emitSound(self.camera_ticks, @intCast(playback.owner), id) catch {
            self.replay_unsupported = .coordinator_action;
            return;
        };
    }
    const host = self.integrationHost().?;
    var party_slots: [6]unite_systems.Slot = undefined;
    var enemy_slots: [6]unite_systems.Slot = undefined;
    const view = self.uniteView(&party_slots, &enemy_slots);
    var ctx = UniteContext{ .state = self, .boundary = boundary, .leader = playback.owner, .target_enemy = 0 };
    var empty = systems.Draws{};
    const draws = self.replay_draws orelse &empty;
    for (0..self.enemyCount()) |enemy| if (events.hits & (@as(u6, 1) << @as(u3, @intCast(enemy))) != 0) {
        switch (unite_systems.impactSequenceTarget(boundary, host.uniteCatalogue(), view, uniteHost(&ctx), draws, .{ .enemy = enemy })) {
            .applied => |amount| {
                boundary.stage = .impacted;
                boundary.amount +|= amount;
                self.active.?.amount +|= amount;
                self.unite_vm.impact_at[playback.owner] = self.effectTicks();
            },
            .skipped => {},
            .failed => |failure| {
                switch (failure) {
                    .random => |err| {
                        if (err == error.RandomInputExhausted) self.replay_exhausted = true else self.replay_unsupported = .coordinator_action;
                    },
                    .refusal => self.replay_unsupported = .coordinator_action,
                }
                return;
            },
        }
    };
    if (events.returns) {
        for (boundary.participantsSlice()) |member| self.unite_vm.sequenceDispatch(self.unite_actors.?, member, null) catch {
            self.replay_unsupported = .coordinator_action;
            return;
        };
        self.unite_flags[trigger] &= ~@as(u16, 16);
        self.unite_vm.actors[trigger].signals &= ~@as(u16, 16);
    }
}

pub fn beginMartialQueue(self: *State, owner: usize, timing: battle.unite_queue.Timing) !void {
    const boundary = self.uniteBoundaryFor(owner) orelse return error.InvalidUniteSceneBinding;
    if (self.martial_queue != null or boundary.record_index != 29 or boundary.count != 3 or boundary.stage != .committed) return error.InvalidUniteSceneBinding;
    var pending: [6]bool = @splat(false);
    for (0..self.enemyCount()) |enemy| pending[enemy] = self.enemy_hp[enemy] > 0;
    const queue = try battle.unite_queue.State.init(timing, pending);
    self.martial_queue = .{ .owner = owner, .queue = queue };
}

fn resolveMartialQueue(self: *State, boundary: *unite_systems.Boundary) bool {
    const playback = if (self.martial_queue) |*value| value else return false;
    if (playback.owner != boundary.command_owner) return false;
    if (playback.updated_at == self.camera_ticks) return true;
    playback.updated_at = self.camera_ticks;
    var flags: [3]u16 = undefined;
    for (boundary.participantsSlice(), 0..) |member, ordinal| flags[ordinal] = self.unite_flags[member];
    const events = playback.queue.advance(flags);
    const bundle = self.unite_actors;
    for (boundary.participantsSlice(), 0..) |member, ordinal| {
        if (events.claims[ordinal] != null or events.returns & (@as(u3, 1) << @as(u2, @intCast(ordinal))) != 0) if (bundle == null) {
            self.replay_unsupported = .coordinator_action;
            return true;
        };
        if (events.claims[ordinal]) |enemy| {
            self.unite_vm.sequenceDispatch(self.unite_actors.?, member, @intCast(self.partyCount() + enemy)) catch {
                self.replay_unsupported = .coordinator_action;
                return true;
            };
        } else if (events.returns & (@as(u3, 1) << @as(u2, @intCast(ordinal))) != 0) {
            self.unite_vm.sequenceDispatch(self.unite_actors.?, member, null) catch {
                self.replay_unsupported = .coordinator_action;
                return true;
            };
        }
        self.unite_flags[member] &= ~events.consumed[ordinal];
        self.unite_vm.actors[member].signals &= ~events.consumed[ordinal];
    }
    for (events.reactions) |maybe| if (maybe) |enemy| {
        const target = self.partyCount() + enemy;
        self.startUniteReaction(target, 29, 1, self.uniteReactionOriginQ12(target));
    };
    if (events.recipient_return) for (0..self.enemyCount()) |enemy| {
        const target = self.partyCount() + enemy;
        if (self.enemy_hp[enemy] > 0) self.startUniteReaction(target, 29, 2, self.uniteReactionOriginQ12(target));
    };
    // Return dispatch starts the counter; damage is independent of member completion.
    return !events.damage;
}

pub fn resolveUniteImpact(self: *State) void {
    const host = self.integrationHost() orelse return;
    const actor = self.active.?.actor;
    if (actor >= self.unite_boundaries.len) return;
    var boundary = if (self.unite_boundaries[actor]) |value| value else return;
    if (self.hasLiveUniteActors() and self.unite_actors.?.find(boundary.record_index).?.wave_heights != null) {
        resolveTrickWave(self, &boundary);
        self.unite_boundaries[actor] = boundary;
        return;
    }
    const martial = self.martial_queue != null and self.martial_queue.?.owner == actor;
    if (!martial and self.hasLiveUniteActors() and self.unite_actors.?.find(boundary.record_index).?.target_queue != null) return;
    if (martial and resolveMartialQueue(self, &boundary)) return;
    if (!martial and boundary.sequence != null and self.hasLiveUniteActors()) {
        resolveLiveUniteSequence(self, &boundary);
        self.unite_boundaries[actor] = boundary;
        return;
    }
    if (self.hasLiveUniteActors() and boundary.stage != .committed) return;
    if (self.hasLiveUniteActors()) if (self.unite_actors.?.find(boundary.record_index).?.controller) |spec| {
        if (self.unite_scene == null or self.active.?.scene == null or self.active.?.scene.?.elapsed != spec.damage_at) return;
    };
    if (!martial and self.hasLiveUniteActors()) if (self.unite_actors.?.find(boundary.record_index).?.damage_member) |member| {
        if (!self.unite_vm.signalReady(boundary.participantsSlice()[member], self.unite_actors.?.find(boundary.record_index).?.damage_signal)) return;
    };
    if (self.hasLiveUniteActors()) if (self.unite_actors.?.find(boundary.record_index).?.damage_target_signal) |signal| {
        if (self.unite_flags[self.active.?.target] & signal == 0) return;
    };
    if (self.hasLiveUniteActors()) if (self.unite_actors.?.find(boundary.record_index).?.impact_effect != null) {
        const visual = if (self.active.?.unite_impact_effect) |*value| value else {
            self.replay_unsupported = .coordinator_action;
            return;
        };
        if (visual.started_at == null) visual.started_at = self.camera_ticks;
    };
    var party_slots: [6]unite_systems.Slot = undefined;
    var enemy_slots: [6]unite_systems.Slot = undefined;
    const view = self.uniteView(&party_slots, &enemy_slots);
    var ctx = UniteContext{ .state = self, .boundary = &boundary, .leader = actor, .target_enemy = 0 };
    var empty_draws = systems.Draws{};
    const draws = self.replay_draws orelse &empty_draws;
    const result = if (boundary.sequence != null)
        boundary.advanceSequence(host.uniteCatalogue(), view, uniteHost(&ctx), draws, self.effectTicks()) orelse {
            self.unite_boundaries[actor] = boundary;
            return;
        }
    else
        boundary.impact(host.uniteCatalogue(), view, uniteHost(&ctx), draws);
    switch (result) {
        .applied => |amount| {
            if (self.hasLiveUniteActors()) self.unite_vm.impact_at[actor] = self.effectTicks();
            self.active.?.amount = amount;
            if (self.hasLiveUniteActors()) {
                const binding = self.unite_actors.?.find(boundary.record_index).?;
                if (binding.damage_target_signal) |signal| {
                    const target = self.active.?.target;
                    self.unite_flags[target] &= ~signal;
                    self.unite_vm.actors[target].signals &= ~signal;
                }
                if (binding.damage_signal != 2) if (binding.damage_member) |ordinal| {
                    const slot = boundary.participantsSlice()[ordinal];
                    self.unite_flags[slot] &= ~binding.damage_signal;
                    self.unite_vm.actors[slot].signals &= ~binding.damage_signal;
                };
            }
            self.unite_boundaries[actor] = boundary;
        },
        .skipped => {
            self.active.?.amount = 0;
            if (self.hasLiveUniteActors()) if (self.unite_actors.?.find(boundary.record_index).?.impact_effect != null) {
                const binding = self.unite_actors.?.find(boundary.record_index).?;
                const slot = boundary.participantsSlice()[binding.damage_member.?];
                self.unite_flags[slot] &= ~binding.damage_signal;
                self.unite_vm.actors[slot].signals &= ~binding.damage_signal;
                self.unite_vm.impact_at[actor] = self.effectTicks();
            };
        },
        .failed => |failure| {
            switch (failure) {
                .random => |err| {
                    if (err == error.RandomInputExhausted) self.replay_exhausted = true else self.replay_unsupported = .coordinator_action;
                },
                .refusal => {},
            }
            self.active.?.kind = .unavailable;
            self.active.?.amount = 0;
            self.unite_boundaries[actor] = null;
        },
    }
}

pub fn finishUnite(self: *State) void {
    if (self.integrationHost() == null) return;
    const actor = if (self.active) |effect| effect.actor else return;
    if (actor >= self.unite_boundaries.len) return;
    var boundary = if (self.unite_boundaries[actor]) |value| value else return;
    var party_slots: [6]unite_systems.Slot = undefined;
    var enemy_slots: [6]unite_systems.Slot = undefined;
    const view = self.uniteView(&party_slots, &enemy_slots);
    var ctx = UniteContext{ .state = self, .boundary = &boundary, .leader = actor, .target_enemy = 0 };
    boundary.finish(view, uniteHost(&ctx)) catch {
        self.unite_boundaries[actor] = null;
        return;
    };
    self.unite_boundaries[actor] = null;
}
