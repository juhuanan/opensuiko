//! Explicit modal-priority policy and mode dispatch for journey simulation ticks.
const battle = @import("battle");
const pause = @import("pause_menu");
const journey = @import("../journey.zig");
const exploration = @import("exploration.zig");
const events_host = @import("events_host.zig");
const modes = @import("modes.zig");

/// Priority order when overlapping modal or traversal states could otherwise compete:
/// 1. `teleport` — active teleport menu swallows navigation/confirm before gameplay.
/// 2. `side_game` — cup/card minigames run exclusively until exited.
/// 3. `item_overload` — forced item-overload disposal blocks movement/events.
/// 4. `pending_field_music` — field event waits until the host completes requested BGM swap/fade.
/// 5. `auto_travel` / 6. `boat_travel` — active crossings override free exploration.
/// 7. `dice_or_party_selection` — dice/party-selection frames run in `journey_frame` before field ticks.
/// 8. `field_menu` — open pause menu without an owning field event bypasses room-event admission.
/// 9. `world_or_event` — normal room event admission and mode-specific `tickCore`.
pub const ModalOwner = enum {
    teleport,
    side_game,
    item_overload,
    pending_field_music,
    auto_travel,
    boat_travel,
    dice_or_party_selection,
    field_menu,
    world_or_event,
};

pub fn modalOwner(state: *const journey.State, input: pause.Input) ModalOwner {
    if (state.teleport_session != null) return .teleport;
    if (state.side_game != null) return .side_game;
    if (state.item_overload != null) return .item_overload;
    if (state.pendingFieldMusic() != null) return .pending_field_music;
    if (state.auto_travel != null) return .auto_travel;
    if (exploration.shouldTickBoat(state, input)) return .boat_travel;
    if (state.dice_game != null or state.party_selection != null) return .dice_or_party_selection;
    if (state.field_event == null and state.menu.phase != .closed) return .field_menu;
    return .world_or_event;
}

fn tickTeleport(state: *journey.State, input: pause.Input) !void {
    var session = state.teleport_session.?;
    const command: journey.travel.teleport.Input = if (input.field.cancel)
        .cancel
    else if (input.field.action)
        .confirm
    else if (input.left)
        .left
    else if (input.right)
        .right
    else switch (input.field.menu_direction orelse return) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
    };
    if (command == .confirm and session.visibleCount() == 0) return;
    switch (try session.tick(command)) {
        .none => state.teleport_session = session,
        .cancelled => state.teleport_session = null,
        .confirmed => |proposal| {
            try journey.travel.commitTeleport(&session, state.package, &state.field_state, proposal);
            state.combat.progress = state.field_state.progress;
            state.teleport_session = null;
            try exploration.onRoomChange(state, false);
        },
    }
}

pub noinline fn tickWithFieldEvents(state: *journey.State, input: pause.Input, combat_input: battle.Input) !pause.Effect {
    switch (modalOwner(state, input)) {
        .teleport => {
            try tickTeleport(state, input);
            return .none;
        },
        .side_game => {
            try journey.side_games.tick(state, input);
            state.elapsed_ticks +|= 1;
            return .none;
        },
        .item_overload => {
            try journey.overload.tick(state, input);
            state.elapsed_ticks +|= 1;
            return .none;
        },
        .pending_field_music => return .none,
        .auto_travel => {
            try exploration.tickAutomaticTravel(state);
            return .none;
        },
        .boat_travel => {
            try exploration.tickBoat(state, input.field.direction);
            return .none;
        },
        .dice_or_party_selection => {
            if (state.dice_game != null and !journey.dice.usesModel(state)) try journey.dice.tickPlain(state, input);
            state.elapsed_ticks +|= 1;
            return .none;
        },
        .field_menu => return tickCore(state, input, combat_input, .disabled),
        .world_or_event => {},
    }

    try events_host.initializeRoomVisit(state);
    const consumed_action = try events_host.admitRoomEvent(state, input.field, .all);
    const owner = state.field_event orelse {
        if (exploration.handleReadyFieldEncounter(state)) return .none;
        const effect = try tickCore(state, input, combat_input, .enabled);
        if (state.mode == .field and state.menu.phase == .closed) if (state.field_state.wheel_state) |*wheel| wheel.advance();
        return effect;
    };
    if (state.mode != .field) {
        const effect = try tickCore(state, input, combat_input, .enabled);
        if (state.scripted_battle) |active| if (active.confirmed != null) {
            try events_host.resumeScriptedBattle(state, owner.session, owner.binding.*);
        };
        return effect;
    }
    return events_host.tickActiveFieldEvent(state, owner, input, consumed_action);
}

pub fn tickCore(state: *journey.State, input: pause.Input, combat_input: battle.Input, room_events: journey.RoomEventMode) !pause.Effect {
    if (exploration.shouldTickBoat(state, input)) {
        try exploration.tickBoat(state, input.field.direction);
        return .none;
    }
    if (state.auto_travel != null) {
        try exploration.tickAutomaticTravel(state);
        return .none;
    }
    if (state.dice_game != null or state.party_selection != null) {
        state.elapsed_ticks +|= 1;
        return .none;
    }
    if (state.mode == .game_over) return .none;
    if (state.mode != .field or state.menu.phase == .closed) state.elapsed_ticks +|= 1;
    state.bind();

    return switch (state.mode) {
        .game_over => .none,
        .duel => blk: {
            try modes.tickDuel(state, combat_input.up, combat_input.down, combat_input.confirm);
            break :blk .none;
        },
        .ending => blk: {
            try modes.tickEnding(state, combat_input.up, combat_input.down, combat_input.confirm);
            break :blk .none;
        },
        .war => blk: {
            try modes.tickWar(state, .{
                .up = input.field.menu_direction == .up,
                .down = input.field.menu_direction == .down,
                .left = input.left,
                .right = input.right,
                .confirm = combat_input.confirm,
                .cancel = combat_input.cancel,
            });
            break :blk .none;
        },
        .defeat => blk: {
            modes.tickDefeat(state, combat_input);
            break :blk .none;
        },
        .battle => blk: {
            modes.tickBattle(state, combat_input);
            break :blk .none;
        },
        .field => exploration.tickFieldExploration(state, input, room_events),
    };
}
