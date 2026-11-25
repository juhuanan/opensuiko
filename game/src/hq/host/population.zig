const std = @import("std");
const hq_host = @import("../host.zig");
const scene_mod = @import("../scene.zig");
const windows_mod = @import("../windows.zig");

const Host = hq_host.Host;

pub const Construction = struct {
    rooms: []const scene_mod.RoomView,
    actors: []const scene_mod.ActorView,
    skipped_unproved_actors: u16,
    skipped_unproved_entrances: u16,
};

/// Reconstruct the current stage's reachable rooms and present actors.  An
/// unproved doorway/actor is skipped by HQ scene construction, never defaulted.
pub fn construction(self: *Host) !Construction {
    var state = self.sceneState();
    const facts = try state.facts();
    const built = try scene_mod.reconstruct(&self.scenes.value, facts, &self.room_buffer, &self.actor_buffer);
    return .{
        .rooms = built.rooms,
        .actors = built.actors,
        .skipped_unproved_actors = built.skipped_unproved_actors,
        .skipped_unproved_entrances = built.skipped_unproved_entrances,
    };
}

pub fn stageEntry(self: *const Host) !*const scene_mod.StageEntry {
    return scene_mod.findStage(self.scenes.value, try self.stage()) orelse error.UnknownStage;
}

/// The HQ recruitment window bound to one constructed actor, if any.  The binding
/// is the source area file plus the entity index plus the identity byte --
/// a catalogue/portrait match alone is never a window.
fn windowForActor(self: *Host, entry: *const scene_mod.StageEntry, actor: scene_mod.ActorView) ?*const windows_mod.Window {
    for (self.windows.asset().windows) |*window| {
        if (!std.mem.eql(u8, window.area.source_file, entry.area.file)) continue;
        if (window.area.entity_id != actor.source_character_id) continue;
        if (window.area.room_entity != actor.entity_index) continue;
        return window;
    }
    return null;
}

fn serviceActorFor(_: *Host, entry: *const scene_mod.StageEntry, actor: scene_mod.ActorView) ?scene_mod.ServiceActor {
    for (entry.service_actors) |service| {
        if (std.mem.eql(u8, service.id, actor.id)) return service;
    }
    return null;
}

/// Rebuild the current room's interaction list from the current facts.
pub fn rebuild(self: *Host) !void {
    self.interaction_count = 0;
    self.cursor = 0;
    self.blocker = null;
    if (self.area) |area_id| {
        try rebuildArea(self, area_id);
        return;
    }
    const entry = try stageEntry(self);
    const built = try construction(self);
    for (built.actors) |actor| {
        if (actor.room != self.room) continue;
        if (self.interaction_count == hq_host.max_interactions) return error.TooManyInteractions;
        if (windowForActor(self, entry, actor)) |window| {
            push(self, .{
                .kind = .recruit,
                .id = actor.id,
                .room = actor.room,
                .entity_index = actor.entity_index,
                .identity = actor.source_character_id,
                .window = window.id,
            });
        } else if (serviceActorFor(self, entry, actor)) |service| {
            push(self, .{
                .kind = .service_unbound,
                .id = actor.id,
                .room = actor.room,
                .entity_index = actor.entity_index,
                .identity = actor.source_character_id,
                .blocker = service.binding_status,
            });
        } else {
            push(self, .{
                .kind = .inspect,
                .id = actor.id,
                .room = actor.room,
                .entity_index = actor.entity_index,
                .identity = actor.source_character_id,
            });
        }
    }
    // The tablet's field object is not yet bound; the host exposes it
    // as a declared entry only, in the landing room.
    if (self.room == entry.landing.room and self.interaction_count < hq_host.max_interactions) {
        push(self, .{ .kind = .tablet, .id = "stars_of_destiny_tablet", .room = self.room, .declared = true, .blocker = "tablet_entry_unbound" });
    }
}

fn rebuildArea(self: *Host, area_id: []const u8) !void {
    for (self.services.value.callers) |*caller| {
        if (!std.mem.eql(u8, caller.area, area_id)) continue;
        if (self.interaction_count == hq_host.max_interactions) return error.TooManyInteractions;
        push(self, .{ .kind = .service_caller, .id = caller.id, .room = caller.room, .entity_index = caller.entity });
    }
}

fn push(self: *Host, interaction: hq_host.Interaction) void {
    self.interactions[self.interaction_count] = interaction;
    self.interaction_count += 1;
}
