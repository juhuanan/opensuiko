const std = @import("std");
const battle = @import("battle.zig");
const host = @import("battle_actor_host.zig");
const layout = @import("battle_layout.zig");
const physical_art = @import("battle_physical_host.zig");
const State = battle.State;

fn position(self: *const State, actor: usize) [3]i32 {
    const point = layout.worldPosition(self, actor);
    return .{ @intFromFloat(@round(point.x * 4096)), @intFromFloat(@round(point.y * 4096)), @intFromFloat(@round(point.z * 4096)) };
}
fn dispatchPartyRecipient(self: *State, bundle: *const host.Bundle, runtime: *host.Runtime, owner: usize, recipient: usize, program: []const u8) !void {
    if (self.unite_vm.owns(recipient)) return error.ActorAlreadyOwned;
    if (self.unite_vm.scripted_actors[recipient]) |existing| {
        if (existing.family != .enemy_magic or existing.leader != owner) return error.ActorAlreadyOwned;
    }
    const id = self.progress.party.at(recipient).id;
    const resource_index = for (bundle.animations.resources, 0..) |resource, index| {
        if (std.mem.eql(u8, resource.id, id)) break index;
    } else return error.MissingActorResource;
    runtime.actors[recipient] = try host.Actor.init(bundle.animations.resources[resource_index], position(self, recipient));
    runtime.actors[recipient].screen_offset = self.actor_transforms[recipient].screen_offset;
    self.unite_vm.scripted_actors[recipient] = .{ .family = .enemy_magic, .leader = @intCast(owner), .resource = @intCast(resource_index) };
    try runtime.dispatch(@intCast(recipient), @intCast(owner), bundle.programs.find(program).?);
}
pub fn beginEnemyMagic(self: *State, owner: usize, recipient: usize) !void {
    const bundle = self.unite_actors orelse return error.MissingActorLibrary;
    if (owner < self.partyCount() or owner >= self.partyCount() + self.enemyCount() or recipient >= self.partyCount() or !self.participates(owner)) return error.InvalidActorBinding;
    const enemy_id = self.enemy(owner - self.partyCount()).id;
    const area_binding = bundle.areaMagicFor(enemy_id);
    const single_binding = if (area_binding == null) (bundle.enemy_magic orelse return error.MissingEnemyMagicBinding) else null;
    if (single_binding) |binding| if (!std.mem.eql(u8, enemy_id, binding.id)) return error.InvalidActorBinding;
    const retained = if (self.enemy_branch_selection) |selection| selection.owner == owner and selection.recipient == recipient else false;
    if (!self.participates(recipient) and (!retained or self.departed[recipient])) return error.InvalidActorBinding;
    if (self.active != null or self.unite_vm.ownsActor(owner) or self.unite_vm.enemy_magic_actions[owner] != null) return error.ActorAlreadyOwned;
    for (0..self.partyCount()) |actor| if (!battle.revival.committedPartyInactive(self.*, actor) and
        (self.party_knockouts[actor].pending or self.coordinatorLocked(actor))) return error.ActorAlreadyOwned;
    const resource = bundle.animations.find(enemy_id) orelse return error.MissingActorResource;
    const target_resource = bundle.animations.find(self.progress.party.at(recipient).id) orelse return error.MissingActorResource;
    if (area_binding) |binding| {
        if (self.content.presentation_ready) {
            const spell_art = (self.spell_scenes orelse return error.MissingEnemyMagicArt).enemy_magic_art orelse return error.MissingEnemyMagicArt;
            if (binding.kind().? == .sorcerer and spell_art.center(self.progress.party.at(recipient).id, target_resource.find(0).?.frames[0].pose) == null) return error.MissingEnemyMagicArt;
            if (binding.kind().? == .earth_golem and (!spell_art.hasClip(.golem_rock) or !spell_art.hasClip(.golem_impact))) return error.MissingEnemyMagicArt;
            try physical_art.checkProgramArt(self.*, bundle.library(), resource, binding.owner_program, 0, 0, false);
            if (!binding.group) {
                try physical_art.checkProgramArt(self.*, bundle.library(), target_resource, binding.recipient_program, 0, 0, false);
            } else for (0..self.partyCount()) |slot| if (!battle.revival.committedPartyInactive(self.*, slot)) {
                const slot_res = bundle.animations.find(self.progress.party.at(slot).id) orelse return error.MissingActorResource;
                if (binding.kind().? == .earth_golem and spell_art.center(self.progress.party.at(slot).id, slot_res.find(0).?.frames[0].pose) == null) return error.MissingEnemyMagicArt;
                try physical_art.checkProgramArt(self.*, bundle.library(), slot_res, binding.recipient_program, 0, 0, false);
                if (binding.wave_recipient_program) |wave_program| try physical_art.checkProgramArt(self.*, bundle.library(), slot_res, wave_program, 0, 0, false);
            };
        }
        if (!binding.group) {
            if (self.progress.party.at(recipient).rune != null and self.runeByteFor(recipient) == null) return error.MissingBattleRuneData;
        } else for (0..self.partyCount()) |slot| if (!battle.revival.committedPartyInactive(self.*, slot)) {
            if (self.progress.party.at(slot).rune != null and self.runeByteFor(slot) == null) return error.MissingBattleRuneData;
        };
        self.unite_vm.auxiliary_capacity = @intCast(19 - self.partyCount() - self.enemyCount());
        self.unite_vm.enemy_magic_actions[owner] = .{
            .owner = @intCast(owner),
            .recipient = @intCast(recipient),
            .start_at = self.camera_ticks +% 1,
            .group = binding.group,
            .area = @import("battle_enemy_magic.zig").AreaState.init(binding.kind().?),
        };
    } else {
        const binding = single_binding.?;
        if (self.content.presentation_ready) {
            const spell_art = (self.spell_scenes orelse return error.MissingEnemyMagicArt).enemy_magic_art orelse return error.MissingEnemyMagicArt;
            if (spell_art.center(self.progress.party.at(recipient).id, target_resource.find(0).?.frames[0].pose) == null) return error.MissingEnemyMagicArt;
            try physical_art.checkProgramArt(self.*, bundle.library(), resource, binding.owner_program, 0, 0, false);
            try physical_art.checkProgramArt(self.*, bundle.library(), target_resource, binding.recipient_program, 0, 0, false);
        }
        if (self.progress.party.at(recipient).rune != null and self.runeByteFor(recipient) == null) return error.MissingBattleRuneData;
        self.unite_vm.auxiliary_capacity = @intCast(19 - self.partyCount() - self.enemyCount());
        self.unite_vm.enemy_magic_actions[owner] = .{ .owner = @intCast(owner), .recipient = @intCast(recipient), .start_at = self.camera_ticks +% 1 };
    }
    self.active = .{ .actor = owner, .target = recipient, .kind = .enemy_magic };
    self.acted[owner] = true;
    if (self.coordinator) |*clock| clock.stage = .await_order;
}
pub fn prepareEnemyMagic(self: *State, owner: usize, runtime: *host.Runtime) !void {
    const bundle = self.unite_actors.?;
    const playback = &self.unite_vm.enemy_magic_actions[owner].?;
    if (playback.prepared or self.unite_vm.ownsActor(owner)) return error.ActorAlreadyOwned;
    const enemy_id = self.enemy(owner - self.partyCount()).id;
    const owner_program = if (bundle.areaMagicFor(enemy_id)) |area| area.owner_program else bundle.enemy_magic.?.owner_program;
    const resource = bundle.animations.find(enemy_id).?;
    const resource_index = for (bundle.animations.resources, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id, resource.id)) break index;
    } else return error.MissingActorResource;
    runtime.actors[owner] = try @import("battle_enemy_idle.zig").prepareActor(self, owner, resource, position(self, owner));
    runtime.actors[owner].screen_offset = self.actor_transforms[owner].screen_offset;
    self.unite_vm.scripted_actors[owner] = .{ .family = .enemy_magic, .leader = @intCast(owner), .resource = @intCast(resource_index) };
    playback.prepared = true;
    try runtime.dispatch(@intCast(owner), playback.recipient, bundle.programs.find(owner_program).?);
}
pub fn beginEnemyMagicEffect(self: *State, owner: usize) !void {
    if (owner >= self.unite_vm.enemy_magic_actions.len or self.unite_vm.enemy_magic_actions[owner] == null) return error.MissingEnemyMagicBinding;
    try self.unite_vm.enemy_magic_actions[owner].?.beginEffect();
}
pub fn advanceEnemyMagicActor(self: *State, owner: usize, runtime: *host.Runtime) !void {
    if (owner >= self.unite_vm.enemy_magic_actions.len) return;
    const playback = if (self.unite_vm.enemy_magic_actions[owner]) |*value| value else return;
    if (!playback.prepared) return;
    const bundle = self.unite_actors.?;
    if (playback.area != null) {
        const enemy_id = self.enemy(owner - self.partyCount()).id;
        const binding = bundle.areaMagicFor(enemy_id) orelse return error.MissingEnemyMagicBinding;
        var party_q12: [6][3]i32 = @splat(.{ 0, 0, 0 });
        var party_active: [6]bool = @splat(false);
        for (0..self.partyCount()) |slot| {
            party_q12[slot] = position(self, slot);
            party_active[slot] = !battle.revival.committedPartyInactive(self.*, slot);
        }
        const event = try playback.advanceArea(binding, &runtime.actors[owner], party_q12, party_active, self);
        if (event.camera_pulse_z_q12) |delta_z| {
            if (self.actor_camera) |*controller| {
                controller.velocity[0][2] = delta_z;
                controller.remaining[0] = 1;
            } else self.enemy_magic_pulse = .{ .issued_at = self.camera_ticks, .delta_q12 = delta_z };
        }
        if (event.wave_reaction) {
            const wave_program = binding.wave_recipient_program orelse return error.InvalidEnemyMagicBinding;
            for (0..self.partyCount()) |slot| if (party_active[slot]) {
                try dispatchPartyRecipient(self, bundle, runtime, owner, slot, wave_program);
                const bit = @as(u8, 1) << @intCast(slot);
                playback.group_recipients_started |= bit;
                playback.group_recipients_done &= ~bit;
            };
        }
        if (event.reaction) {
            if (!binding.group) {
                const recipient = playback.recipient;
                if (playback.recipient_started or self.unite_vm.ownsActor(recipient)) return error.ActorAlreadyOwned;
                try dispatchPartyRecipient(self, bundle, runtime, owner, recipient, binding.recipient_program);
                playback.recipient_started = true;
            } else for (0..self.partyCount()) |slot| if (party_active[slot]) {
                try dispatchPartyRecipient(self, bundle, runtime, owner, slot, binding.recipient_program);
                const bit = @as(u8, 1) << @intCast(slot);
                playback.group_recipients_started |= bit;
                playback.group_recipients_done &= ~bit;
            };
        }
        if (event.damage) {
            if (!binding.group) {
                const recipient = playback.recipient;
                const inactive = battle.revival.committedPartyInactive(self.*, recipient);
                if (playback.amount != null) return error.DuplicateEnemyMagicDamage;
                const rune = if (self.progress.party.at(recipient).rune == null) 0 else self.runeByteFor(recipient) orelse return error.MissingBattleRuneData;
                const draw = try battle.enemy_magic.nextBattleDraw(self);
                const computed = binding.damage(self.stats(owner).magic, self.stats(recipient).magic, rune, draw, recipient);
                playback.amount = if (self.actor_conditions[recipient].protection_rounds == 0) computed else 0;
                self.enemy_magic_damage[recipient] = .{ .issued_at = self.camera_ticks, .amount = playback.amount.? };
                self.progress.party.at(recipient).hp = @intCast(@as(u32, self.hp(recipient)) -| playback.amount.?);
                if (!inactive) self.markPartyKnockout(recipient);
                if (self.active) |*effect| if (effect.kind == .enemy_magic and effect.actor == owner) {
                    effect.amount = playback.amount.?;
                    effect.affected |= @as(u16, 1) << @intCast(recipient);
                    effect.amounts[recipient] = @intCast(playback.amount.?);
                };
            } else {
                var total: u32 = 0;
                for (0..self.partyCount()) |slot| if (party_active[slot]) {
                    if (playback.group_amounts[slot] != null) return error.DuplicateEnemyMagicDamage;
                    const rune = if (self.progress.party.at(slot).rune == null) 0 else self.runeByteFor(slot) orelse return error.MissingBattleRuneData;
                    const draw = try battle.enemy_magic.nextBattleDraw(self);
                    const computed = binding.damage(self.stats(owner).magic, self.stats(slot).magic, rune, draw, slot);
                    const amount = if (self.actor_conditions[slot].protection_rounds == 0) computed else 0;
                    playback.group_amounts[slot] = amount;
                    total += amount;
                    self.enemy_magic_damage[slot] = .{ .issued_at = self.camera_ticks, .amount = amount };
                    self.progress.party.at(slot).hp = @intCast(@as(u32, self.hp(slot)) -| amount);
                    self.markPartyKnockout(slot);
                    if (self.active) |*effect| if (effect.kind == .enemy_magic and effect.actor == owner) {
                        effect.affected |= @as(u16, 1) << @intCast(slot);
                        effect.amounts[slot] = @intCast(amount);
                    };
                };
                playback.amount = total;
                if (self.active) |*effect| if (effect.kind == .enemy_magic and effect.actor == owner) {
                    effect.amount = total;
                };
            }
        }
        if (playback.phase == .running) for (binding.worker.sounds) |sound| if (sound.update == playback.update) {
            try self.unite_vm.emitSound(self.camera_ticks, @intCast(owner), sound.id);
        };
        return;
    }
    const binding = bundle.enemy_magic.?;
    const recipient = playback.recipient;
    const event = playback.advance(binding, &runtime.actors[owner], position(self, recipient));
    if (event.contact) {
        if (self.actor_camera) |*controller| {
            controller.velocity[0][2] = binding.effect.shock_size;
            controller.remaining[0] = binding.effect.shock_updates;
        } else self.enemy_magic_pulse = .{ .issued_at = self.camera_ticks, .delta_q12 = binding.effect.shock_size };
    }
    if (event.reaction) {
        if (playback.recipient_started or self.unite_vm.ownsActor(recipient)) return error.ActorAlreadyOwned;
        try dispatchPartyRecipient(self, bundle, runtime, owner, recipient, binding.recipient_program);
        playback.recipient_started = true;
    }
    if (event.damage) {
        const inactive = battle.revival.committedPartyInactive(self.*, recipient);
        if (playback.amount != null) return error.DuplicateEnemyMagicDamage;
        const rune = if (self.progress.party.at(recipient).rune == null) 0 else self.runeByteFor(recipient) orelse return error.MissingBattleRuneData;
        const draw = self.roll();
        if (self.replay_exhausted) return error.RandomInputExhausted;
        const computed = binding.damage(self.stats(owner).magic, self.stats(recipient).magic, rune, draw);
        playback.amount = if (self.actor_conditions[recipient].protection_rounds == 0) computed else 0;
        self.enemy_magic_damage[recipient] = .{ .issued_at = self.camera_ticks, .amount = playback.amount.? };
        self.progress.party.at(recipient).hp = @intCast(@as(u32, self.hp(recipient)) -| playback.amount.?);
        if (!inactive) self.markPartyKnockout(recipient);
        if (self.active) |*effect| {
            if (effect.kind == .enemy_magic and effect.actor == owner) effect.amount = playback.amount.?;
        }
    }
    if (playback.phase == .running) for (binding.effect.sounds) |sound| if (sound.update == playback.update) {
        try self.unite_vm.emitSound(self.camera_ticks, @intCast(owner), sound.id);
    };
}
pub fn finishEnemyMagicActors(self: *State) void {
    for (&self.unite_vm.enemy_magic_actions, 0..) |*maybe, owner| if (maybe.*) |*playback| {
        if (!playback.prepared) continue;
        if (!playback.group) {
            for ([_]u8{ playback.recipient, playback.owner }, 0..) |actor, role| {
                const binding = self.unite_vm.scripted_actors[actor] orelse continue;
                if (binding.family != .enemy_magic or binding.leader != owner) continue;
                const current = &self.unite_vm.actors[actor];
                if (current.machine == null or !current.machine.?.halted or current.highlights != 0 or current.palette_cycle_active) continue;
                if (role == 1 and playback.phase != .complete) continue;
                if (self.content.world_art == null) self.actor_transforms[actor].screen_offset = current.screen_offset;
                self.unite_vm.scripted_actors[actor] = null;
                self.actor_transforms[actor].node_angles = .{ 0, 0, 0 };
                if (role == 0) playback.recipient_done = true else {
                    playback.owner_done = true;
                    if (self.active) |effect| {
                        if (effect.kind == .enemy_magic and effect.actor == owner) self.active = null;
                    }
                    if (self.coordinator) |*clock| if (clock.current_actor == owner) {
                        clock.completed = true;
                        const delay = if (playback.area != null)
                            self.unite_actors.?.areaMagicFor(self.enemy(owner - self.partyCount()).id).?.selection_delay
                        else
                            self.unite_actors.?.enemy_magic.?.selection_delay;
                        clock.remaining = delay;
                        clock.stage = .select;
                    };
                }
            }
            if (playback.owner_done and playback.recipient_done) maybe.* = null;
        } else {
            for (0..self.partyCount()) |slot| {
                const binding = self.unite_vm.scripted_actors[slot] orelse continue;
                if (binding.family != .enemy_magic or binding.leader != owner) continue;
                const current = &self.unite_vm.actors[slot];
                if (current.machine == null or !current.machine.?.halted or current.highlights != 0 or current.palette_cycle_active) continue;
                if (self.content.world_art == null) self.actor_transforms[slot].screen_offset = current.screen_offset;
                self.unite_vm.scripted_actors[slot] = null;
                self.actor_transforms[slot].node_angles = .{ 0, 0, 0 };
                playback.group_recipients_done |= @as(u8, 1) << @intCast(slot);
            }
            if (self.unite_vm.scripted_actors[owner]) |binding| if (binding.family == .enemy_magic and binding.leader == owner) {
                const current = &self.unite_vm.actors[owner];
                if (current.machine != null and current.machine.?.halted and current.highlights == 0 and !current.palette_cycle_active and playback.phase == .complete) {
                    if (self.content.world_art == null) self.actor_transforms[owner].screen_offset = current.screen_offset;
                    self.unite_vm.scripted_actors[owner] = null;
                    self.actor_transforms[owner].node_angles = .{ 0, 0, 0 };
                    playback.owner_done = true;
                    if (self.active) |effect| {
                        if (effect.kind == .enemy_magic and effect.actor == owner) self.active = null;
                    }
                    if (self.coordinator) |*clock| if (clock.current_actor == owner) {
                        clock.completed = true;
                        const delay = self.unite_actors.?.areaMagicFor(self.enemy(owner - self.partyCount()).id).?.selection_delay;
                        clock.remaining = delay;
                        clock.stage = .select;
                    };
                }
            };
            if (playback.owner_done and playback.allRecipientsDone()) maybe.* = null;
        }
    };
}
