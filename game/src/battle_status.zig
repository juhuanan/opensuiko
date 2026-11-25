//! Status application, immunity, sleep recovery and round-boundary status ticks.
const std = @import("std");
const systems = @import("battle_rules");

pub const IconClock = struct { active: u8 = 0, started_at: [8]u32 = @splat(0) };

pub fn partyIconMask(state: anytype, actor: usize) u8 {
    const member = state.progress.party[actor];
    const persistent = state.knockout_status[actor] orelse member.status;
    var mask: u8 = if (persistent == .poisoned) 1 else 0;
    for (0..member.balloons) |index| mask |= @as(u8, 1) << @intCast(index + 1);
    if (state.accuracy_reduced[actor]) mask |= 16;
    if (state.asleep[actor] > 0) mask |= 32;
    if (state.rune_blocked[actor]) mask |= 64;
    if (state.unbalanced[actor] > 0) mask |= 128;
    return mask;
}

pub fn advanceIcons(state: anytype) void {
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

pub fn statusImmune(state: anytype, actor: usize) bool {
    return actor < state.partyCount() and state.hasRune(actor, "turtle");
}

pub fn requestUniteRecovery(state: anytype, actor: usize, round_boundaries: u8) !void {
    if (actor >= state.partyCount() or round_boundaries == 0) return error.InvalidActorRecovery;
    if (statusImmune(state, actor)) return;
    _ = state.roll();
    if (state.replay_exhausted) return error.RandomInputExhausted;
    // Acquisition consumes its draw before checking the existing recovery flag.
    if (state.unbalanced[actor] == 0) state.unbalanced[actor] = round_boundaries;
}

pub fn requestActorStatus(state: anytype, actor: usize, attempt: anytype) !void {
    const party = actor < state.partyCount();
    // shortcut: add enemy poison/balloon state before admitting those recipients.
    if (actor >= state.partyCount() + state.enemyCount() or attempt.threshold_percent > 100 or (!party and (attempt.kind == .poison or attempt.kind == .balloon))) return error.InvalidActorStatus;
    if (statusImmune(state, actor)) return;
    const draw = state.roll();
    if (state.replay_exhausted) return error.RandomInputExhausted;
    const below = systems.statusPercent(draw) < attempt.threshold_percent;
    if (below != party) return;
    _ = setStatus(state, actor, attempt.kind);
}

pub fn requestUniteEnemySleep(state: anytype, actor: usize, failure_percent: u8) !void {
    if (actor < state.partyCount() or actor >= state.partyCount() + state.enemyCount() or failure_percent > 100) return error.InvalidActorStatus;
    const draw = state.roll();
    if (state.replay_exhausted) return error.RandomInputExhausted;
    // The actor opcode draws even if the enemy Sleep bit is already set.
    if (systems.statusPercent(draw) >= failure_percent) _ = inflictStatus(state, actor, .sleep);
}

pub fn inflictStatus(state: anytype, target: usize, ailment: anytype) bool {
    if (target >= state.partyCount() + state.enemyCount() or !state.participates(target) or statusImmune(state, target)) return false;
    return setStatus(state, target, ailment);
}

fn setStatus(state: anytype, target: usize, ailment: anytype) bool {
    advanceIcons(state);
    defer advanceIcons(state);
    if (ailment == .sleep) {
        if (state.asleep[target] > 0) return false;
        state.asleep[target] = 1;
        if (target < state.partyCount()) state.acted[target] = true;
        return true;
    }
    if (ailment == .accuracy_reduced or ailment == .rune_blocked) {
        const flag = if (ailment == .accuracy_reduced) &state.accuracy_reduced[target] else &state.rune_blocked[target];
        if (flag.*) return false;
        flag.* = true;
        return true;
    }
    if (target >= state.partyCount()) return false;
    const member = &state.progress.party[target];
    if (ailment == .poison) {
        if ((state.knockout_status[target] orelse member.status) == .poisoned) return false;
        // Recipient scripts precede down-state commitment, even at zero HP.
        if (state.knockout_status[target] != null) {
            state.knockout_status[target] = .poisoned;
        } else member.status = .poisoned;
        if (state.revivals[target]) |*revival| revival.original_status = .poisoned;
    } else {
        if (state.gearIndex(.pointed_hat)) |hat| if (state.loadouts[target].head == hat) return false;
        if (member.balloons == 3) return false;
        member.balloons += 1;
    }
    return true;
}

pub fn applyRoundBoundaryStatuses(state: anytype) void {
    for (state.progress.party, 0..) |member, index| {
        if (member.balloons == 3) state.beginDeparture(index);
    }
    state.promoteRearMembers();
    for (&state.protection) |*rounds| rounds.* -|= 1;
    if (state.content.systems != null) for (state.progress.party, 0..) |*member, index| {
        if (state.participates(index) and state.protection[index] == 0) {
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

pub fn recoverSleep(state: anytype, actor: usize) void {
    if (state.asleep[actor] == 0) return;
    if (state.content.systems.?.sleep_recovery_percent) |percent| {
        // The source reset rolls only for living enemies, after the party loop.
        if (actor < state.partyCount() or !state.participates(actor)) return;
        if (@as(u32, state.roll()) * 100 / 32767 < percent) state.asleep[actor] = 0;
    } else state.asleep[actor] -= 1;
}

pub fn clearKnockoutStatuses(state: anytype, target: usize) void {
    state.progress.party[target].balloons = 0;
    state.asleep[target] = 0;
    state.accuracy_reduced[target] = false;
    state.rune_blocked[target] = false;
    state.unbalanced[target] = 0;
    state.protection[target] = 0;
    state.acted[target] = true;
}
