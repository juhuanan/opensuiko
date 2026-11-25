//! Save/load slot picking, save naming, confirmations, new game confirmation, and menu notices.
const pause = @import("../pause_menu.zig");
const nav = @import("navigation.zig");

pub fn handle(state: *pause.State, input: pause.Input) pause.Effect {
    switch (state.phase) {
        .save_slots, .load_slots => {
            nav.cycleUpDown(&state.save_slot, pause.save_slots.count, input.field.menu_direction);
            if (input.field.action) {
                const entry = state.summaries[state.save_slot];
                state.yes = false;
                if (entry.status == .future) {
                    state.notify("This slot requires a newer build. Choose another slot.");
                } else if (state.phase == .save_slots) {
                    state.save_label = entry.name;
                    state.phase = .name_save;
                } else if (entry.status == .ready or entry.status == .backup) {
                    state.phase = .confirm_load;
                } else state.notify(if (entry.status == .empty) "This slot is empty." else "This slot has no valid save or backup.");
            }
        },
        .name_save => {
            if (input.erase) state.save_label.erase();
            state.save_label.append(input.text);
            if (input.field.action) {
                state.save_label.validate() catch {
                    state.save_label = pause.save_slots.defaultLabel(state.save_slot);
                };
                state.yes = false;
                state.phase = .confirm_save;
            }
        },
        .confirm_save, .confirm_load => {
            nav.toggleConfirm(&state.yes, input);
            if (input.field.action) {
                if (!state.yes) {
                    state.phase = nav.leaveFacility(state);
                } else {
                    const effect: pause.Effect = if (state.phase == .confirm_save) .save else .load;
                    state.notify(if (effect == .save) "Saving..." else "Loading...");
                    return effect;
                }
            }
        },
        .confirm_new_game => {
            nav.toggleConfirm(&state.yes, input);
            if (input.field.action) {
                if (!state.yes) {
                    state.phase = .root;
                } else {
                    state.phase = .closed;
                    return .new_game;
                }
            }
        },
        .notice => if (input.field.action) {
            state.phase = nav.leaveFacility(state);
        },
        else => unreachable,
    }
    return .none;
}
