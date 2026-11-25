//! Shop buy/sell flow and stock confirmation.
const field = @import("field");
const pause = @import("../../pause_menu.zig");
const nav = @import("../navigation.zig");

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) void {
    switch (state.phase) {
        .shop => {
            nav.cycleUpDown(&state.shop_choice, 3, input.field.menu_direction);
            if (input.field.action) {
                state.phase = switch (state.shop_choice) {
                    0 => .buy_member,
                    1 => .sell_items,
                    else => .closed,
                };
                if (state.phase == .closed) {
                    state.shop_stock_len = 0;
                    state.shop_allow_equipment = false;
                }
                state.slot = 0;
                state.yes = false;
            }
        },
        .buy_member => {
            nav.cycleLeftRight(&state.member, game.progress.party.len, input.left, input.right);
            const stock = state.shopStock(game.item_rules.?);
            const stock_count = stock.len;
            if (stock_count > 0) {
                nav.cycleUpDown(&state.stock_slot, stock_count, input.field.menu_direction);
                if (input.field.action) {
                    state.yes = false;
                    state.phase = .confirm_buy;
                }
            }
        },
        .confirm_buy => {
            nav.toggleConfirm(&state.yes, input);
            if (input.field.action) {
                if (!state.yes) {
                    state.phase = .buy_member;
                } else {
                    state.message = "Bought item for the selected member.";
                    const stock = state.shopStock(game.item_rules.?);
                    (if (state.shop_allow_equipment) game.progress.buyShopGood(game.item_rules.?, stock, stock[state.stock_slot], state.member) else game.progress.buyItem(game.item_rules.?, stock[state.stock_slot], state.member)) catch |err| {
                        state.message = switch (err) {
                            error.InsufficientFunds => "You do not have enough bits.",
                            error.InventoryFull => "That member carries nine items.",
                            else => "The purchase could not be completed.",
                        };
                    };
                    state.phase = .shop_notice;
                }
            }
        },
        .sell_items => {
            nav.cycleLeftRight(&state.member, game.progress.party.len, input.left, input.right);
            const slots = game.progress.party[state.member].inventory.count();
            state.slot = @min(state.slot, slots -| 1);
            if (slots > 0) {
                nav.cycleUpDown(&state.slot, slots, input.field.menu_direction);
                if (input.field.action) {
                    if (state.combat != null and state.combat.?.itemEquipped(state.member, state.slot)) {
                        state.message = "Remove this item in Equipment first.";
                        state.phase = .shop_notice;
                        return;
                    }
                    _ = (if (state.shop_allow_equipment) game.progress.shopSalePrice(game.item_rules.?, state.member, state.slot) else game.progress.salePrice(game.item_rules.?, state.member, state.slot)) catch {
                        state.message = "The merchant cannot buy this item.";
                        state.phase = .shop_notice;
                        return;
                    };
                    state.yes = false;
                    state.phase = .confirm_sell;
                }
            }
        },
        .confirm_sell => {
            nav.toggleConfirm(&state.yes, input);
            if (input.field.action) {
                if (!state.yes) {
                    state.phase = .sell_items;
                } else {
                    state.message = "Sold the selected item bundle.";
                    (if (state.shop_allow_equipment) game.progress.sellShopItem(game.item_rules.?, state.member, state.slot) else game.progress.sellItem(game.item_rules.?, state.member, state.slot)) catch {
                        state.message = "The sale could not be completed.";
                    };
                    state.phase = .shop_notice;
                    state.slot = @min(state.slot, game.progress.party[state.member].inventory.count() -| 1);
                }
            }
        },
        .shop_notice => if (input.field.action) {
            state.phase = .shop;
        },
        else => unreachable,
    }
}
