//! Rune master attach and detach service flow.
const field = @import("field");
const pause = @import("../../pause_menu.zig");
const nav = @import("../navigation.zig");
const runes = @import("../runes.zig");

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) void {
    switch (state.phase) {
        .rune_service => {
            nav.cycleLeftRight(&state.member, game.progress.party.len, input.left, input.right);
            nav.cycleUpDown(&state.service_action, 3, input.field.menu_direction);
            if (input.field.action) {
                state.target = state.member;
                state.yes = false;
                state.slot = 0;
                state.phase = switch (state.service_action) {
                    0 => .rune_attach,
                    1 => .confirm_rune_remove,
                    else => if (state.rune_from_menu) .rune else .closed,
                };
                if (state.phase == .rune) runes.selectFieldSpell(state);
            }
        },
        .rune_attach => {
            nav.cycleLeftRight(&state.member, game.progress.party.len, input.left, input.right);
            const slots = game.progress.party[state.member].inventory.count();
            state.slot = @min(state.slot, slots -| 1);
            if (slots > 0) {
                nav.cycleUpDown(&state.slot, slots, input.field.menu_direction);
                if (input.field.action) {
                    state.yes = false;
                    state.phase = .confirm_rune_attach;
                }
            }
        },
        .confirm_rune_attach, .confirm_rune_remove => {
            nav.toggleConfirm(&state.yes, input);
            if (input.field.action) {
                if (!state.yes) {
                    state.phase = if (state.phase == .confirm_rune_attach) .rune_attach else .rune_service;
                } else {
                    state.message = "Rune changed. Spell charges preserved.";
                    const result = if (state.phase == .confirm_rune_attach)
                        state.combat.?.attachRune(state.target, state.member, state.slot)
                    else
                        state.combat.?.detachRune(state.target);
                    result catch |err| {
                        state.message = switch (err) {
                            error.RuneLocked => "This rune cannot be removed or replaced.",
                            error.RuneOccupied => "Remove the current rune first.",
                            error.IncompatibleRune => "This character cannot use that rune.",
                            error.InventoryFull => "Make room in this member's bag first.",
                            else => "No usable rune or crystal was selected.",
                        };
                    };
                    state.member = state.target;
                    state.character_page = .rune_service;
                    state.phase = .character_notice;
                }
            }
        },
        else => unreachable,
    }
}
