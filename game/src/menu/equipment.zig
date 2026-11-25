//! Equipment slots, character status/strength inspection, and shared character notices.
const field = @import("field");
const pause = @import("../pause_menu.zig");
const nav = @import("navigation.zig");

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) pause.Effect {
    switch (state.phase) {
        .equipment => {
            nav.cycle(&state.member, game.progress.party.len, input.left, input.right);
            var slot_index: usize = @backingInt(state.equipment_slot);
            nav.cycleUpDown(&slot_index, 5, input.field.menu_direction);
            state.equipment_slot = @fromBackingInt(@intCast(slot_index));
            if (input.field.action) {
                state.phase = .equipment_items;
                state.slot = 0;
            }
        },
        .equipment_items => {
            const combat = state.combat.?;
            const choices = game.progress.party[state.member].inventory.count() + 1;
            nav.cycleUpDown(&state.slot, choices, input.field.menu_direction);
            if (input.field.action) {
                const item = if (state.slot == 0) null else combat.gearIndex(game.progress.party[state.member].inventory.slots[state.slot - 1].?.id) orelse {
                    state.message = "This is not wearable equipment.";
                    state.character_page = .equipment_items;
                    state.phase = .character_notice;
                    return .none;
                };
                state.message = "Equipment changed.";
                if (input.party_transactions) {
                    state.character_page = .equipment;
                    state.phase = .character_notice;
                    return .party_equip;
                }
                combat.equipSlotOwned(state.member, state.equipment_slot, item) catch |err| {
                    state.message = if (err == error.ItemUnavailable) "You do not own a spare of this item." else "This member cannot equip that item here.";
                };
                state.character_page = .equipment;
                state.phase = .character_notice;
            }
        },
        .strength => {
            if (input.field.menu_direction != null) state.strength_details = !state.strength_details;
            nav.cycle(&state.member, game.progress.party.len, input.left, input.right);
            if (input.field.action) state.phase = .root;
        },
        .character_notice => if (input.field.action) {
            state.phase = state.character_page;
        },
        else => unreachable,
    }
    return .none;
}
