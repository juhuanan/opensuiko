//! Vault storage deposit/withdrawal service flow.
const field = @import("field");
const pause = @import("../../pause_menu.zig");
const nav = @import("../navigation.zig");

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) void {
    switch (state.phase) {
        .storage => {
            nav.cycleUpDown(&state.service_action, 3, input.field.menu_direction);
            if (input.field.action) {
                if (state.service_action == 2) {
                    state.phase = nav.leaveFacility(state);
                } else {
                    state.storage_withdraw = state.service_action == 1;
                    state.phase = .storage_items;
                    state.member = 0;
                    state.slot = 0;
                }
            }
        },
        .storage_items => {
            nav.cycleLeftRight(&state.member, game.progress.party.len, input.left, input.right);
            const count = if (state.storage_withdraw) game.progress.storage.count() else game.progress.party[state.member].inventory.count();
            if (count == 0) {
                state.slot = 0;
                return;
            }
            state.slot = @min(state.slot, count - 1);
            nav.cycleUpDown(&state.slot, count, input.field.menu_direction);
            if (input.field.action) {
                state.storage_id = if (state.storage_withdraw) game.progress.storage.itemAt(state.slot) else game.progress.party[state.member].inventory.slots[state.slot].?.id;
                state.phase = .confirm_storage;
                state.yes = false;
            }
        },
        .confirm_storage => {
            nav.toggleConfirm(&state.yes, input);
            if (input.field.action) {
                if (!state.yes) {
                    state.phase = .storage_items;
                } else {
                    const result = if (state.storage_withdraw)
                        game.progress.storage.withdraw(&game.progress.party[state.member].inventory, state.storage_id.?)
                    else
                        state.combat.?.depositToStorage(&game.progress.storage, state.member, state.slot);
                    if (result) |_| {
                        state.message = if (state.storage_withdraw) "Item withdrawn." else "Item deposited.";
                    } else |err| state.message = switch (err) {
                        error.StorageFull => "Already storing 254 of this item.",
                        error.InventoryFull => "This member's inventory is full.",
                        error.EquippedItem => "Remove worn equipment before storing it.",
                        error.AppraisalRequired => "Appraise the urn before storing it.",
                        else => "The transfer could not be completed.",
                    };
                    state.phase = .storage_notice;
                }
            }
        },
        .storage_notice => if (input.field.action) {
            state.phase = .storage_items;
        },
        else => unreachable,
    }
}
