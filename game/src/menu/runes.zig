//! Field rune inspection and ally healing/casting selection.
const field = @import("field");
const pause = @import("../pause_menu.zig");
const nav = @import("navigation.zig");

pub fn selectFieldSpell(state: *pause.State) void {
    const combat = state.combat.?;
    state.slot = if (state.travel_context) 0 else 4;
    const rune = combat.rune(state.member) orelse return;
    for (rune.spells, 0..) |slot, tier| if (slot) |spell| {
        if (combat.content.systems.?.spells[spell].allies and combat.content.systems.?.spells[spell].field_use and combat.canCast(state.member, spell)) {
            state.slot = tier;
            return;
        }
    };
}

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) void {
    const combat = state.combat.?;
    const count = game.progress.party.len;
    switch (state.phase) {
        .rune => {
            nav.cycleLeftRight(&state.member, count, input.left, input.right);
            if (input.left or input.right) selectFieldSpell(state);
            const slots: usize = if (state.travel_context) 4 else 5;
            nav.cycleUpDown(&state.slot, slots, input.field.menu_direction);
            if (input.field.action) {
                if (state.slot == 4) {
                    if (state.travel_context) return;
                    state.rune_from_menu = true;
                    state.service_action = 0;
                    state.phase = .rune_service;
                    return;
                }
                const rune = combat.rune(state.member) orelse return;
                const spell = rune.spells[state.slot] orelse return;
                if ((!combat.content.systems.?.spells[spell].allies or !combat.content.systems.?.spells[spell].field_use) or !combat.canCast(state.member, spell)) return;
                state.target = state.member;
                state.phase = .rune_target;
            }
        },
        .rune_target => {
            nav.cycleUpDown(&state.target, count, input.field.menu_direction);
            if (input.field.action) {
                const spell = combat.rune(state.member).?.spells[state.slot].?;
                state.message = "Rune used. One charge consumed.";
                combat.castFieldSpell(state.member, spell, state.target) catch {
                    state.message = "No valid target. No rune charge consumed.";
                };
                state.character_page = .rune;
                state.phase = .character_notice;
            }
        },
        else => unreachable,
    }
}
