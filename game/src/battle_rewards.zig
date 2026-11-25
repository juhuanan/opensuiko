//! Battle reward readiness, money/experience awards and drop placement.
const std = @import("std");
const field = @import("field");
const State = @import("battle.zig").State;

pub fn rewardReady(state: *const State) bool {
    return state.dropped_item == null or state.drop_received or state.loot_declined;
}

pub fn commitRewards(state: *State) void {
    if (state.rewards_committed) return;
    state.rewards_committed = true;
    state.reward_levels = state.levels;
    if (state.content.encounters[state.encounter].reward_policy == .none) return;
    state.reward_money = 0;
    for (0..state.enemyCount()) |index| state.reward_money +|= state.enemy(index).money;
    for (0..state.partyCount()) |member| if (state.hasRune(member, "prosperity")) {
        state.reward_money *|= 2;
    };
    const previous_money = state.progress.money;
    state.progress.money = @intCast(@min(field.game_state.max_money, @as(u64, state.progress.money) + state.reward_money));
    state.reward_received = state.progress.money - previous_money;
    for (0..state.partyCount()) |index| {
        if (!state.participates(index)) continue;
        const award = experienceAward(state, index);
        state.award_exp[index] = award;
        state.experience[index] +|= award;
        if (state.content.systems != null) state.applyExperience(index);
    }
    for (0..state.enemyCount()) |i| {
        if (state.dropped_item != null) break;
        if (state.enemy(i).drops) |drops| {
            const candidate = drops[state.roll() % 3];
            if (candidate.item) |id| if (state.roll() % 100 < candidate.rate) {
                state.dropped_item = .{ .id = id, .uses = candidate.uses, .identified = candidate.identified };
            };
        }
    }
    if (state.dropped_item != null or state.reward_drop) {
        if (state.dropped_item == null) state.dropped_item = .{ .id = .medicine, .uses = state.rules.medicine.uses };
        for (state.progress.party, 0..) |*member, recipient| {
            const count = member.inventory.count();
            if (count == 9) continue;
            member.inventory.slots[count] = state.dropped_item.?;
            state.drop_received = true;
            state.loot_recipient = recipient;
            break;
        }
    }
}

pub fn experienceAward(state: *const State, index: usize) u32 {
    if (state.content.encounters[state.encounter].reward_policy == .none) return 0;
    const rules = state.content.systems orelse return state.content.encounters[state.encounter].experience_per_member;
    if (!state.participates(index)) return 0;
    var award: u32 = 0;
    for (0..state.enemyCount()) |enemy_index| {
        const difference = std.math.clamp(@as(i32, state.enemy(enemy_index).level) - state.levels[index], -14, 15);
        award +|= rules.experience[@intCast(difference + 14)];
    }
    return @max(5, award / @as(u32, @intCast(state.partyCount()))) * @as(u32, if (state.hasRune(index, "fortune")) 2 else 1);
}
