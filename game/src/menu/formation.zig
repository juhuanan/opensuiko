//! Party formation swap selection.
const field = @import("field");
const pause = @import("../pause_menu.zig");

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) void {
    const count = game.progress.party.len;
    const choice = if (state.phase == .formation) &state.member else &state.target;
    if (input.field.menu_direction == .up or input.left) choice.* = (choice.* + count - 1) % count;
    if (input.field.menu_direction == .down or input.right) choice.* = (choice.* + 1) % count;
    if (input.field.action) {
        if (state.phase == .formation) {
            state.target = state.member;
            state.phase = .formation_target;
        } else {
            const combat = state.combat.?;
            combat.swapFormation(state.member, state.target) catch unreachable;
            state.phase = .formation;
        }
    }
}
