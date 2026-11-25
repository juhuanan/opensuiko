//! Party inventory, shared items, item actions, transfers, discards, and healing/weapon-piece usage.
const field = @import("field");
const pause = @import("../pause_menu.zig");
const nav = @import("navigation.zig");

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) pause.Effect {
    switch (state.phase) {
        .items => return handleItems(state, game, input),
        .shared_items => if (input.left != input.right) {
            state.member = if (input.left) game.progress.party.len - 1 else 0;
            state.slot = 0;
            state.phase = .items;
        },
        .item_action => return handleItemAction(state, game, input),
        .item_transfer => return handleItemTransfer(state, game, input),
        .confirm_discard => return handleConfirmDiscard(state, game, input),
        .item_target => return handleItemTarget(state, game, input),
        .confirm_weapon_piece => return handleConfirmWeaponPiece(state, input),
        .item_notice => if (input.field.action) {
            state.phase = .items;
        },
        else => unreachable,
    }
    return .none;
}

fn handleItems(state: *pause.State, game: *field.State, input: pause.Input) pause.Effect {
    const count = game.progress.party.len;
    if (input.has_shared_items and input.left != input.right and
        ((input.left and state.member == 0) or (input.right and state.member + 1 == count)))
    {
        state.phase = .shared_items;
        return .none;
    }
    nav.cycleLeftRight(&state.member, count, input.left, input.right);
    const slots = game.progress.party[state.member].inventory.count();
    if (slots == 0) {
        state.slot = 0;
        return .none;
    }
    state.slot = @min(state.slot, slots - 1);
    nav.cycleUpDown(&state.slot, slots, input.field.menu_direction);
    if (input.field.action and game.item_rules != null) {
        state.target = state.member;
        const selected = game.progress.party[state.member].inventory.slots[state.slot].?.id;
        if (selected == .sacrificial_buddha and state.combat == null) {
            state.message = "Revives its bearer automatically in battle.";
            state.phase = .item_notice;
            return .none;
        }
        if (game.item_rules.?.consumable(selected)) |definition| if (!definition.field_usable) {
            state.message = "This item can only be used in battle.";
            state.phase = .item_notice;
            return .none;
        };
        state.phase = if (state.combat != null) .item_action else .item_target;
        state.item_action = 0;
    }
    return .none;
}

fn handleItemAction(state: *pause.State, game: *field.State, input: pause.Input) pause.Effect {
    nav.cycleUpDown(&state.item_action, 3, input.field.menu_direction);
    if (input.field.action) {
        const item = game.progress.party[state.member].inventory.slots[state.slot].?;
        state.target = state.member;
        if (state.item_action == 0) {
            if (item.id == .blinking_mirror and input.travel_tools) return .blinking_mirror;
            if (input.weapon_pieces and item.id.weaponPiece()) {
                state.phase = .item_target;
            } else if (game.item_rules.?.consumable(item.id)) |definition| {
                if (definition.field_usable) state.phase = .item_target else {
                    state.message = "This item can only be used in battle.";
                    state.phase = .item_notice;
                }
            } else {
                state.message = if (item.id == .sacrificial_buddha) "Revives its bearer automatically in battle." else "This item's use is not available\nin this episode.";
                state.phase = .item_notice;
            }
        } else if (state.combat.?.itemEquipped(state.member, state.slot)) {
            state.message = "Remove this item in Equipment first.";
            state.phase = .item_notice;
        } else {
            state.yes = false;
            state.phase = if (state.item_action == 1) .item_transfer else .confirm_discard;
        }
    }
    return .none;
}

fn handleItemTransfer(state: *pause.State, game: *field.State, input: pause.Input) pause.Effect {
    nav.cycleUpDown(&state.target, game.progress.party.len, input.field.menu_direction);
    if (input.field.action) {
        state.message = "Item given to the selected member.";
        if (input.party_transactions) {
            state.phase = .item_notice;
            return .party_give;
        }
        game.progress.transfer(state.member, state.slot, state.target) catch |err| {
            state.message = if (err == error.InventoryFull) "That member's inventory is full." else "Choose a different member.";
        };
        state.phase = .item_notice;
        state.slot = @min(state.slot, game.progress.party[state.member].inventory.count() -| 1);
    }
    return .none;
}

fn handleConfirmDiscard(state: *pause.State, game: *field.State, input: pause.Input) pause.Effect {
    nav.toggleConfirm(&state.yes, input);
    if (input.field.action) {
        if (!state.yes) {
            state.phase = .item_action;
        } else {
            if (input.party_transactions) {
                state.message = "Item discarded.";
                state.phase = .item_notice;
                return .party_discard;
            }
            game.progress.discard(state.member, state.slot) catch unreachable;
            state.message = "Item discarded.";
            state.phase = .item_notice;
            state.slot = @min(state.slot, game.progress.party[state.member].inventory.count() -| 1);
        }
    }
    return .none;
}

fn handleItemTarget(state: *pause.State, game: *field.State, input: pause.Input) pause.Effect {
    nav.cycleUpDown(&state.target, game.progress.party.len, input.field.menu_direction);
    if (input.field.action) {
        if (input.weapon_pieces and game.progress.party[state.member].inventory.slots[state.slot].?.id.weaponPiece()) {
            state.weapon_piece_replace = false;
            state.phase = .item_notice;
            return .weapon_piece;
        }
        const item = game.item_rules.?.consumable(game.progress.party[state.member].inventory.slots[state.slot].?.id);
        state.message = if (item != null and item.?.cure != null) "Condition cured. One use consumed." else "Recovered HP. One use consumed.";
        game.progress.useItem(game.item_rules.?, state.member, state.slot, state.target) catch |err| {
            state.message = switch (err) {
                error.BattleOnlyItem => "This item can only be used in battle.",
                error.FullHealth => "HP is full. No item was consumed.",
                error.InvalidTarget => "This item cannot revive a member.",
                error.NoEffect => "No condition to cure. No item consumed.",
                else => "This item could not be used.",
            };
        };
        state.phase = .item_notice;
        state.slot = @min(state.slot, game.progress.party[state.member].inventory.count() -| 1);
    }
    return .none;
}

fn handleConfirmWeaponPiece(state: *pause.State, input: pause.Input) pause.Effect {
    nav.toggleConfirm(&state.yes, input);
    if (input.field.action) {
        if (!state.yes) {
            state.phase = .item_target;
        } else {
            state.weapon_piece_replace = true;
            state.phase = .item_notice;
            return .weapon_piece;
        }
    }
    return .none;
}
