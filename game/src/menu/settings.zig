//! Setup/preferences menu row navigation and adjustment.
const pause = @import("../pause_menu.zig");
const nav = @import("navigation.zig");

pub fn handle(state: *pause.State, input: pause.Input) pause.Effect {
    if (input.field.cancel or input.menu) {
        state.phase = .root;
        return .none;
    }
    nav.cycleUpDown(&state.setup_row, 4, input.field.menu_direction);
    if (input.left or input.right or input.field.action) {
        state.preferences.adjust(state.setup_row, !input.left);
        return .settings_changed;
    }
    return .none;
}
