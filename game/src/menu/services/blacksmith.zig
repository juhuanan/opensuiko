//! Blacksmith weapon sharpening selection and confirmation.
const field = @import("field");
const pause = @import("../../pause_menu.zig");
const nav = @import("../navigation.zig");

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) void {
    switch (state.phase) {
        .blacksmith => {
            const count = game.progress.party.len;
            if (input.left or input.field.menu_direction == .up) state.member = (state.member + count - 1) % count;
            if (input.right or input.field.menu_direction == .down) state.member = (state.member + 1) % count;
            if (input.field.action) {
                _ = state.combat.?.sharpenPrice(state.member, state.service_limit) catch {
                    state.message = "I cannot sharpen this weapon further.";
                    state.character_page = .blacksmith;
                    state.phase = .character_notice;
                    return;
                };
                state.yes = false;
                state.phase = .confirm_blacksmith;
            }
        },
        .confirm_blacksmith => {
            nav.toggleConfirm(&state.yes, input);
            if (input.field.action) {
                if (!state.yes) {
                    state.phase = .blacksmith;
                } else {
                    state.message = "Weapon sharpened.";
                    state.combat.?.sharpen(state.member, state.service_limit, &game.progress.money) catch |err| {
                        state.message = if (err == error.InsufficientFunds) "You do not have enough bits." else "I cannot sharpen this weapon further.";
                    };
                    state.character_page = .blacksmith;
                    state.phase = .character_notice;
                }
            }
        },
        else => unreachable,
    }
}
