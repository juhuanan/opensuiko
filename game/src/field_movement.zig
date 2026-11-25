//! Field step completion, exit transitions and event triggers.
//! Parameterized over the field state so it does not import field.zig.

pub fn advance(state: anytype) bool {
    state.movement_updates +%= 1;
    state.remaining -= 1;
    state.animation_ticks +%= 1;
    if (state.remaining != 0) return false;
    state.x = state.destination.x;
    state.y = state.destination.y;
    return true;
}

pub fn finish(state: anytype, package: anytype) void {
    const room = package.rooms[state.room];
    for (room.exits) |exit| {
        if (exit.direction != null and exit.direction.? != state.facing) continue;
        if (state.x >= exit.x and state.x < exit.x + exit.w and state.y >= exit.y and state.y < exit.y + exit.h) {
            if (!exit.allows(&state.progress.story, &state.local_flags)) continue;
            state.enterRoom(package.roomIndex(exit.room).?, .{ .x = exit.spawn_x, .y = exit.spawn_y });
            if (room.boat_rapids != null) if (state.progress.story.scenario) |*story| {
                if (story.world_mode == 1) story.world_mode = 0;
            };
            if (exit.world_entry) |id| state.setWorldEntry(package, id) else state.reconcileWorldEntry(package, null);
            if (exit.arrival_facing) |facing| state.facing = facing;
            state.crossed_world_exit = exit.world_exit;
            return;
        }
    }
    _ = triggerEvent(state, package.rooms[state.room]);
}

pub fn triggerEvent(state: anytype, room: anytype) bool {
    for (room.events, 0..) |event, i| {
        if ((event.requires == null or state.progress.story.has(event.requires.?)) and !state.progress.story.has(event.flag) and state.x >= event.x and state.x < event.x + event.w and state.y >= event.y and state.y < event.y + event.h) {
            state.progress.story.complete(event.flag);
            state.dialogue = .{ .source = .{ .event = i }, .reveal_started = state.scene_ticks };
            state.animation_ticks = 0;
            state.walking = false;
            state.action_pending = false;
            return true;
        }
    }
    return false;
}
