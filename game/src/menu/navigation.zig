//! Shared menu cursor helpers, facility exit, and cancel/close transitions.
const field = @import("field");
const pause = @import("../pause_menu.zig");
const runes = @import("runes.zig");

pub fn cycleUpDown(value: *usize, count: usize, dir: ?field.Direction) void {
    if (count == 0) return;
    if (dir == .up) value.* = (value.* + count - 1) % count;
    if (dir == .down) value.* = (value.* + 1) % count;
}

pub fn cycleLeftRight(value: *usize, count: usize, left: bool, right: bool) void {
    if (count == 0) return;
    if (left) value.* = (value.* + count - 1) % count;
    if (right) value.* = (value.* + 1) % count;
}

pub fn toggleConfirm(yes: *bool, input: pause.Input) void {
    if (input.field.menu_direction != null or input.left or input.right) yes.* = !yes.*;
}

pub fn themeSelectionStep(input: pause.Input) u8 {
    if (input.left or input.field.menu_direction == .up or input.field.menu_direction == .left) return 4;
    if (input.right or input.field.menu_direction == .down or input.field.menu_direction == .right) return 1;
    return 0;
}

pub fn resetTransientServiceFlags(state: *pause.State) void {
    state.shop_stock_len = 0;
    state.shop_allow_equipment = false;
    state.appraisal_from_service = false;
}

pub fn leaveFacility(state: *pause.State) pause.Phase {
    const result: pause.Phase = if (state.field_facility != null) .closed else .root;
    state.field_facility = null;
    state.tablet_view = null;
    state.jukebox_playing = null;
    return result;
}

pub fn handleCancel(state: *pause.State) void {
    if (state.phase == .rune_attach) state.member = state.target;
    if (state.phase == .sound_theme) state.pending_sound = 0x503;
    state.phase = switch (state.phase) {
        .root, .shop, .blacksmith => .closed,
        .rune_service => if (state.rune_from_menu) .rune else .closed,
        .rune_attach, .confirm_rune_remove => .rune_service,
        .name_save => .save_slots,
        .confirm_new_game => .root,
        .save_slots, .storage, .notice, .bathhouse, .bath, .tablet, .library, .window_style, .window_color, .sound_theme, .jukebox => leaveFacility(state),
        .library_reading => .library,
        .confirm_save => if (state.field_facility == .save_point) .save_slots else .root,
        .load_slots => .root,
        .appraisal => if (state.appraisal_from_service) .closed else .root,
        .confirm_appraisal, .appraisal_notice => .appraisal,
        .storage_items => .storage,
        .confirm_storage, .storage_notice => .storage_items,
        .confirm_rune_attach => .rune_attach,
        .confirm_blacksmith => .blacksmith,
        .buy_member, .sell_items, .shop_notice => .shop,
        .confirm_buy => .buy_member,
        .confirm_sell => .sell_items,
        .item_action, .item_notice => .items,
        .item_transfer, .confirm_discard => .item_action,
        .item_target => if (state.combat != null) .item_action else .items,
        .confirm_weapon_piece => .item_target,
        .formation_target => .formation,
        .rune_target => .rune,
        .equipment_items => .equipment,
        .character_notice => state.character_page,
        else => .root,
    };
    if (state.phase == .closed) resetTransientServiceFlags(state);
    if (state.phase == .rune) runes.selectFieldSpell(state);
}

pub fn closeAll(state: *pause.State) void {
    state.phase = .closed;
    state.field_facility = null;
    state.tablet_view = null;
    state.jukebox_playing = null;
    resetTransientServiceFlags(state);
}
