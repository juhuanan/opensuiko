//! Holly Fairy's primary callback delegates AI; actor scripts own the wave clock.
const std = @import("std");
const host = @import("battle_actor_host.zig");

pub const Event = enum { none, completed };
pub const Decision = enum { no_action, ordinary_attack, started, stop };
pub const selection_delay = 30;
pub const Binding = struct {
    id: []const u8,
    owner_program: []const u8,

    pub fn validate(self: Binding, library: host.Library) !void {
        if (!std.mem.eql(u8, self.id, "holly_fairy") or
            !std.mem.eql(u8, self.owner_program, "melee/holly_fairy/wave_owner") or
            library.resources.find(self.id) == null or library.programs.find(self.owner_program) == null) return error.InvalidEnemyWaveBinding;
    }
};
pub const Playback = struct {
    owner: u8,
    start_at: u32,
    action: ?Action = null,
    completed_at: ?u32 = null,
};
pub const Action = struct {
    owner: u8,
    completed: bool = false,

    pub fn begin(runtime: *host.Runtime, owner: u8) !Action {
        const library = runtime.library orelse return error.MissingActorLibrary;
        if (owner >= runtime.actors.len or runtime.actors[owner].resource == null or
            !std.mem.eql(u8, runtime.actors[owner].resource.?.id, "holly_fairy")) return error.InvalidActorBinding;
        const program = library.programs.find("melee/holly_fairy/wave_owner") orelse return error.MissingActorProgram;
        try runtime.dispatch(owner, owner, program);
        return .{ .owner = owner };
    }

    // Poll once before the actor sweep; a delegated special may replace this primary.
    pub fn advance(self: *Action, runtime: *host.Runtime, context: anytype) !Event {
        if (self.completed) return .none;
        if (self.owner >= runtime.actors.len) return error.InvalidActorBinding;
        switch (runtime.actors[self.owner].shared_value) {
            1 => {
                defer context.restoreOwner(self.owner);
                for (context.partyCount()..context.partyCount() + context.enemyCount()) |actor| {
                    if (!context.eligible(actor)) continue;
                    switch (try context.decision(actor)) {
                        .no_action => context.restoreWave(self.owner),
                        .ordinary_attack => {
                            // The original callback consumes the turn even when the resolver refuses.
                            _ = try context.ordinary(actor);
                            context.markStarted(actor);
                            break;
                        },
                        .started => {
                            context.markStarted(actor);
                            break;
                        },
                        .stop => break,
                    }
                }
            },
            99 => {
                self.completed = true;
                return .completed;
            },
            else => {},
        }
        return .none;
    }
};
