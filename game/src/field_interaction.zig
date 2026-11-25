//! Field NPC interaction from the pending action flag.
const field = @import("field.zig");
pub fn reaches(state: *const field.State, package: field.Package, x: i32, y: i32) bool {
    const offset = package.interaction_offsets[@backingInt(state.facing)];
    return @abs(state.x + offset.x - x) <= 8 and @abs(state.y + offset.y - y) <= 8;
}

pub fn interact(state: *field.State, package: field.Package, room: field.Room) bool {
    if (!state.action_pending) return false;
    state.action_pending = false;
    for (room.npcs, 0..) |npc, i| {
        if (!npc.visible(state.progress.story)) continue;
        if (reaches(state, package, npc.x, npc.y)) {
            state.dialogue = .{ .source = .{ .npc = i }, .reveal_started = state.scene_ticks };
            state.animation_ticks = 0;
            state.walking = false;
            return true;
        }
    }
    return false;
}
