//! Inventory-driven revival runs after actor reactions, with one owner per member.
const field = @import("field");
const battle = @import("battle.zig");
const status = @import("battle_status.zig");

pub const Revival = struct {
    started_at: u32,
    origin: battle.Position,
    screen_offset: [2]i16 = .{ 0, 0 },
    original_status: field.game_state.Status,
    amount: u16 = 0,
};

pub fn hasBuddha(self: battle.State, actor: usize) bool {
    if (actor >= self.partyCount() or self.rules.automatic_revival == null) return false;
    const inventory = self.progress.party.at(actor).inventory;
    for (inventory.slots[0..inventory.count()]) |item| if (item.?.id == .sacrificial_buddha) return true;
    return false;
}

pub fn committedPartyInactive(self: battle.State, actor: usize) bool {
    return self.departed[actor] or (self.hp(actor) == 0 and !self.party_knockouts[actor].pending and self.party_knockouts[actor].revival == null);
}

pub fn markPartyKnockout(self: *battle.State, actor: usize) void {
    if (self.progress.party.at(actor).hp != 0) return;
    if (self.medicine_action) |*item| {
        if (item.ticks < item.timing.impact_tick) item.interrupt(actor);
    }
    const knockout = &self.party_knockouts[actor];
    if (!knockout.pending) knockout.prior_status = self.progress.party.at(actor).status;
    knockout.pending = true;
    self.progress.party.at(actor).status = .unconscious;
}

pub fn hasPendingRevival(self: battle.State) bool {
    for (0..self.partyCount()) |actor| if (!self.departed[actor] and
        (self.party_knockouts[actor].revival != null or (self.party_knockouts[actor].pending and hasBuddha(self, actor)))) return true;
    return false;
}

/// True commits an ordinary down state; false retains the Buddha recipient lock.
pub fn commitPartyKnockout(self: *battle.State, actor: usize) bool {
    const knockout = &self.party_knockouts[actor];
    if (knockout.revival != null) return false;
    if (!self.departed[actor] and hasBuddha(self.*, actor)) {
        const origin = battle.layout.worldPosition(self, actor);
        const generic_offset = self.uniteScreenOffset(actor);
        const screen_offset = if (self.content.world_art) |art| battle.world_art.actorSample(art, self, actor).sample.offset else [2]i16{ generic_offset[0], generic_offset[1] };
        const inventory = &self.progress.party.at(actor).inventory;
        for (0..inventory.count()) |slot| if (inventory.slots[slot].?.id == .sacrificial_buddha) {
            inventory.remove(slot);
            if (self.actions[actor]) |*queued| {
                if (queued.* == .item and queued.item.slot > slot) queued.item.slot -= 1;
            }
            knockout.revival = .{ .started_at = self.camera_ticks, .origin = origin, .screen_offset = screen_offset, .original_status = knockout.prior_status orelse self.progress.party.at(actor).status };
            knockout.pending = true;
            if (self.active) |*effect| if (effect.protector == actor) {
                effect.protector_revival_delay += self.rules.automatic_revival.?.release_delay;
            };
            return false;
        };
    }
    knockout.* = .{};
    self.progress.party.at(actor).status = .unconscious;
    status.clearKnockoutStatuses(self, actor);
    return true;
}

pub fn advanceRevivals(self: *battle.State) void {
    for (0..self.partyCount()) |actor| {
        const knockout = &self.party_knockouts[actor];
        if (knockout.revival) |*instance| {
            const spec = self.rules.automatic_revival.?;
            const age = self.camera_ticks -% instance.started_at;
            if (age == spec.pending_delay) instance.amount = if (self.actor_conditions[actor].protection_rounds == 0) self.progress.party.at(actor).max_hp / spec.hp_divisor else 0;
            if (age == spec.impact_delay and instance.amount != 0) {
                const member = self.progress.party.at(actor);
                const before = member.*;
                member.hp = @min(member.max_hp, member.hp +| instance.amount);
                if (member.status == .unconscious) member.status = if (instance.original_status == .unconscious) .healthy else instance.original_status;
                self.noteItemImpact(actor, before);
                knockout.pending = false;
                knockout.prior_status = null;
                if (self.actions[actor] == null) self.acted[actor] = true;
            }
            if (age < spec.release_delay) continue;
            knockout.revival = null;
            if (self.hp(actor) > 0) continue;
        }
        if (knockout.pending and self.hp(actor) == 0 and !self.coordinatorLocked(actor)) _ = self.commitPartyKnockout(actor);
    }
}

pub fn revivalAge(self: *const battle.State, actor: usize) ?u32 {
    if (actor >= self.partyCount()) return null;
    const instance = self.party_knockouts[actor].revival orelse return null;
    return self.camera_ticks -% instance.started_at;
}

pub fn revivalAllowsWard(self: battle.State, actor: usize) bool {
    const age = revivalAge(&self, actor) orelse return true;
    return age >= self.rules.automatic_revival.?.release_delay and (self.hp(actor) > 0 or !hasBuddha(self, actor));
}

pub fn revivalLight(self: battle.State, actor: usize) u8 {
    const age = revivalAge(&self, actor) orelse return 128;
    const spec = self.rules.automatic_revival.?;
    return if (age >= spec.white_start and age < spec.white_end) @intCast(255 - 4 * (age - spec.white_start)) else 128;
}

pub fn revivalParticlePositions(self: battle.State, actor: usize) ?[4]battle.Position {
    const age = revivalAge(&self, actor) orelse return null;
    const spec = self.rules.automatic_revival.?;
    if (age < spec.clone_motion_start or age >= spec.clone_release) return null;
    const origin = self.party_knockouts[actor].revival.?.origin;
    const offsets = spec.particles[@min(age - spec.clone_motion_start, spec.particles.len - 1)];
    var positions: [4]battle.Position = undefined;
    for (&positions, offsets) |*position, offset| position.* = .{ .x = origin.x + offset[0], .y = origin.y + offset[1], .z = @floatFromInt(spec.particle_plane_z) };
    return positions;
}
