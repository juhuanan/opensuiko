//! Appraisal item selection, fee confirmation, and outcome notices.
const field = @import("field");
const pause = @import("../../pause_menu.zig");
const nav = @import("../navigation.zig");

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) void {
    switch (state.phase) {
        .appraisal => {
            nav.cycle(&state.member, game.progress.party.len, input.left, input.right);
            const inventory = game.progress.party.at(state.member).inventory;
            const count = inventory.count();
            if (count == 0) {
                state.slot = 0;
                return;
            }
            state.slot = @min(state.slot, count - 1);
            nav.cycleUpDown(&state.slot, count, input.field.menu_direction);
            if (input.field.action) {
                const item = inventory.slots[state.slot].?;
                if (item.identified) {
                    state.message = "This item does not need appraisal.";
                    state.phase = .appraisal_notice;
                } else {
                    state.phase = .confirm_appraisal;
                    state.yes = false;
                }
            }
        },
        .confirm_appraisal => {
            nav.toggleConfirm(&state.yes, input);
            if (input.field.action) {
                if (!state.yes) {
                    state.phase = .appraisal;
                } else {
                    if (game.progress.appraise(game.item_rules.?, state.member, state.slot)) |_| {
                        state.message = game.progress.party.at(state.member).inventory.slots[state.slot].?.name();
                    } else |err| state.message = if (err == error.InsufficientFunds) "Not enough bits for appraisal." else "This item cannot be appraised here.";
                    state.phase = .appraisal_notice;
                }
            }
        },
        .appraisal_notice => if (input.field.action) {
            state.phase = .appraisal;
        },
        else => unreachable,
    }
}
