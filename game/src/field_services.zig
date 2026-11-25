//! Field dialogue and service-phase handling.
const field = @import("field.zig");
const std = @import("std");

pub fn handleDialogue(state: *field.State, room: field.Room, input: field.Input) bool {
    if (state.dialogue) |*dialogue| {
        if (input.cancel) {
            state.dialogue = null;
            return true;
        }
        if (dialogue.phase == .pages) {
            const page = dialogue.pages(room)[dialogue.page];
            if (dialogue.revealedLength(page.len, state.scene_ticks) < page.len) {
                if (input.action) dialogue.reveal_complete = true;
                return true;
            }
        }
        if (dialogue.phase == .shop or dialogue.phase == .service) return true;
        if (dialogue.phase == .recruitment_choices) {
            if (input.menu_direction == .up or input.menu_direction == .down) dialogue.choice ^= 1;
            if (input.action) {
                dialogue.phase = if (dialogue.choice == 0) .recruitment_accepted else .recruitment_declined;
                dialogue.page = 0;
            }
            return true;
        }
        if (dialogue.phase == .recruitment_accepted or dialogue.phase == .recruitment_joined or dialogue.phase == .recruitment_declined) {
            if (input.action) {
                const npc = room.npcs[dialogue.source.npc];
                if (dialogue.phase == .recruitment_accepted) dialogue.phase = .recruitment_joined else if (dialogue.phase == .recruitment_declined and dialogue.page + 1 < npc.recruitment.?.declined.len) {
                    dialogue.page += 1;
                } else if (dialogue.phase == .recruitment_declined and npc.service != null) dialogue.phase = .service else state.dialogue = null;
            }
            return true;
        }
        if (dialogue.phase == .choices) {
            if (input.menu_direction == .up or input.menu_direction == .down) dialogue.choice ^= 1;
            if (input.action) {
                if (dialogue.choice == 1) {
                    state.dialogue = null;
                    return true;
                }
                state.progress.stay(state.inn_rules.?.price_per_member) catch |err| {
                    dialogue.phase = if (err == error.InsufficientFunds) .insufficient_funds else .unavailable;
                    return true;
                };
                state.dialogue = null;
                state.rest_ticks = 60;
            }
        } else if (input.action) {
            const npc_index: ?usize = switch (dialogue.source) {
                .npc => |i| i,
                .event, .boat_rapids => null,
            };
            if (dialogue.phase == .pages and dialogue.page + 1 < dialogue.pages(room).len) {
                dialogue.page += 1;
                dialogue.reveal_started = state.scene_ticks;
                dialogue.reveal_complete = false;
            } else if (dialogue.phase == .pages and npc_index != null and room.npcs[npc_index.?].recruitment != null) {
                dialogue.phase = .recruitment_choices;
            } else if (dialogue.phase == .pages and npc_index != null and state.inn_rules != null and
                std.mem.eql(u8, state.inn_rules.?.room, room.id) and
                std.mem.eql(u8, state.inn_rules.?.npc, room.npcs[npc_index.?].id))
            {
                dialogue.phase = .choices;
            } else if (dialogue.phase == .pages and npc_index != null and state.item_rules != null and
                std.mem.eql(u8, state.item_rules.?.room, room.id) and
                std.mem.eql(u8, state.item_rules.?.npc, room.npcs[npc_index.?].id))
            {
                dialogue.phase = .shop;
            } else if (dialogue.phase == .pages and npc_index != null and room.npcs[npc_index.?].service != null) {
                dialogue.phase = .service;
            } else state.dialogue = null;
        }
        return true;
    }
    return false;
}
