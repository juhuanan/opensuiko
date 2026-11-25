//! Status application, immunity, sleep recovery and round-boundary status ticks.
const std = @import("std");
const systems = @import("battle_rules");
const battle = @import("battle.zig");
const ActorStatus = @import("battle_actor_program.zig").Status;

pub const IconClock = struct { active: u8 = 0, started_at: [8]u32 = @splat(0) };

fn partyIconMask(state: *const battle.State, actor: usize) u8 {
    const member = state.progress.party[actor];
    const persistent = state.party_knockouts[actor].prior_status orelse member.status;
    var mask: u8 = if (persistent == .poisoned) 1 else 0;
    for (0..member.balloons) |index| mask |= @as(u8, 1) << @intCast(index + 1);
    if (state.actor_conditions[actor].accuracy_reduced) mask |= 16;
    if (state.actor_conditions[actor].sleep_turns > 0) mask |= 32;
    if (state.actor_conditions[actor].rune_blocked) mask |= 64;
    if (state.unbalanced[actor] > 0) mask |= 128;
    return mask;
}

pub fn advanceIcons(state: *battle.State) void {
    for (0..state.partyCount()) |actor| {
        const mask = partyIconMask(state, actor);
        const clock = &state.status_icons[actor];
        const added = mask & ~clock.active;
        for (0..8) |index| if (added & (@as(u8, 1) << @intCast(index)) != 0) {
            clock.started_at[index] = state.camera_ticks;
        };
        clock.active = mask;
    }
}

pub fn statusImmune(state: *const battle.State, actor: usize) bool {
    return actor < state.partyCount() and state.hasRune(actor, "turtle");
}

pub fn requestUniteRecovery(state: *battle.State, actor: usize, round_boundaries: u8) !void {
    if (actor >= state.partyCount() or round_boundaries == 0) return error.InvalidActorRecovery;
    if (statusImmune(state, actor)) return;
    _ = state.roll();
    if (state.replay_exhausted) return error.RandomInputExhausted;
    // Acquisition consumes its draw before checking the existing recovery flag.
    if (state.unbalanced[actor] == 0) state.unbalanced[actor] = round_boundaries;
}

pub fn requestActorStatus(state: *battle.State, actor: usize, attempt: ActorStatus) !void {
    const party = actor < state.partyCount();
    // shortcut: add enemy poison/balloon state before admitting those recipients.
    if (actor >= state.partyCount() + state.enemyCount() or attempt.threshold_percent > 100 or (!party and (attempt.kind == .poison or attempt.kind == .balloon))) return error.InvalidActorStatus;
    if (statusImmune(state, actor)) return;
    const draw = state.roll();
    if (state.replay_exhausted) return error.RandomInputExhausted;
    const below = systems.statusPercent(draw) < attempt.threshold_percent;
    if (below != party) return;
    _ = setStatus(state, actor, switch (attempt.kind) {
        .poison => .poison,
        .balloon => .balloon,
        .accuracy_reduced => .accuracy_reduced,
        .sleep => .sleep,
        .rune_blocked => .rune_blocked,
    });
}

pub fn requestUniteEnemySleep(state: *battle.State, actor: usize, failure_percent: u8) !void {
    if (actor < state.partyCount() or actor >= state.partyCount() + state.enemyCount() or failure_percent > 100) return error.InvalidActorStatus;
    const draw = state.roll();
    if (state.replay_exhausted) return error.RandomInputExhausted;
    // The actor opcode draws even if the enemy Sleep bit is already set.
    if (systems.statusPercent(draw) >= failure_percent) _ = inflictStatus(state, actor, .sleep);
}

pub fn inflictStatus(state: *battle.State, target: usize, ailment: battle.Ailment) bool {
    if (target >= state.partyCount() + state.enemyCount() or !state.participates(target) or statusImmune(state, target)) return false;
    return setStatus(state, target, ailment);
}

fn setStatus(state: *battle.State, target: usize, ailment: battle.Ailment) bool {
    advanceIcons(state);
    defer advanceIcons(state);
    const conditions = &state.actor_conditions[target];
    if (ailment == .sleep) {
        if (conditions.sleep_turns > 0) return false;
        conditions.sleep_turns = 1;
        if (target < state.partyCount()) state.acted[target] = true;
        return true;
    }
    if (ailment == .accuracy_reduced or ailment == .rune_blocked) {
        const flag = if (ailment == .accuracy_reduced) &conditions.accuracy_reduced else &conditions.rune_blocked;
        if (flag.*) return false;
        flag.* = true;
        return true;
    }
    if (target >= state.partyCount()) return false;
    const member = &state.progress.party[target];
    if (ailment == .poison) {
        if ((state.party_knockouts[target].prior_status orelse member.status) == .poisoned) return false;
        // Recipient scripts precede down-state commitment, even at zero HP.
        if (state.party_knockouts[target].prior_status != null) {
            state.party_knockouts[target].prior_status = .poisoned;
        } else member.status = .poisoned;
        if (state.party_knockouts[target].revival) |*revival| revival.original_status = .poisoned;
    } else {
        if (state.gearIndex(.pointed_hat)) |hat| if (state.loadouts[target].head == hat) return false;
        if (member.balloons == 3) return false;
        member.balloons += 1;
    }
    return true;
}

/// Process departures and formation changes before HP and status timers.
pub fn applyRoundBoundaryStatuses(state: *battle.State) void {
    for (state.progress.party, 0..) |member, index| {
        if (member.balloons == 3) state.beginDeparture(index);
    }
    state.promoteRearMembers();
    for (&state.actor_conditions) |*conditions| conditions.protection_rounds -|= 1;
    if (state.content.systems != null) for (state.progress.party, 0..) |*member, index| {
        if (state.participates(index) and state.actor_conditions[index].protection_rounds == 0) {
            const regeneration: i32 = if (state.hasRune(index, "sunbeam")) 5 else 0;
            const poison: i32 = if (member.status == .poisoned) systems.battlePoison(member.max_hp) else 0;
            member.hp = @intCast(std.math.clamp(@as(i32, member.hp) + regeneration - poison, 0, member.max_hp));
            state.markPartyKnockout(index);
        }
        recoverSleep(state, index);
        state.unbalanced[index] -|= 1;
    };
    if (state.content.systems != null) for (state.partyCount()..state.partyCount() + state.enemyCount()) |index| recoverSleep(state, index);
}

pub fn recoverSleep(state: *battle.State, actor: usize) void {
    if (state.actor_conditions[actor].sleep_turns == 0) return;
    if (state.content.systems.?.sleep_recovery_percent) |percent| {
        // The source reset rolls only for living enemies, after the party loop.
        if (actor < state.partyCount() or !state.participates(actor)) return;
        if (@as(u32, state.roll()) * 100 / 32767 < percent) state.actor_conditions[actor].sleep_turns = 0;
    } else state.actor_conditions[actor].sleep_turns -= 1;
}

pub fn clearKnockoutStatuses(state: *battle.State, target: usize) void {
    state.progress.party[target].balloons = 0;
    const conditions = &state.actor_conditions[target];
    conditions.sleep_turns = 0;
    conditions.accuracy_reduced = false;
    conditions.rune_blocked = false;
    state.unbalanced[target] = 0;
    conditions.protection_rounds = 0;
    state.acted[target] = true;
}
