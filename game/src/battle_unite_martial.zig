//! Martial arts actor dispatch around the source target queue.
const std = @import("std");
const host = @import("battle_actor_host.zig");
const queue = @import("battle_unite_queue.zig");

pub const Binding = struct { id: []const u8, setup: []const u8, strike: []const u8, @"return": []const u8 };
pub const State = struct {
    queue: queue.State,
    members: [3]u16,
    enemies: [6]?u16,
    bindings: [3]Binding,
    started: bool = false,

    pub fn init(runtime: *const host.Runtime, bindings: [3]Binding, members: [3]u16, enemies: [6]?u16, pending: [6]bool, timing: queue.Timing) !State {
        const library = runtime.library orelse return error.MissingActorLibrary;
        for (members, 0..) |actor, i| {
            if (actor >= runtime.actors.len) return error.InvalidActorBinding;
            const resource = runtime.actors[actor].resource orelse return error.MissingActorResource;
            if (!std.mem.eql(u8, resource.id, bindings[i].id)) return error.InvalidActorBinding;
            for (members[0..i]) |other| if (actor == other) return error.InvalidActorBinding;
            for ([_][]const u8{ bindings[i].setup, bindings[i].strike, bindings[i].@"return" }) |name| {
                _ = library.programs.find(name) orelse return error.MissingUniteProgram;
            }
        }
        for (enemies, 0..) |maybe, i| {
            if (pending[i] and maybe == null) return error.InvalidActorBinding;
            if (maybe) |actor| {
                if (actor >= runtime.actors.len) return error.InvalidActorBinding;
                for (members) |member| if (actor == member) return error.InvalidActorBinding;
                for (enemies[0..i]) |other| if (other == actor) return error.InvalidActorBinding;
            }
        }
        return .{ .queue = try queue.State.init(timing, pending), .members = members, .enemies = enemies, .bindings = bindings };
    }

    pub fn start(self: *State, runtime: *host.Runtime) !void {
        if (self.started) return error.ActorAlreadyOwned;
        for (self.members, self.bindings) |actor, binding| try runtime.dispatch(actor, null, runtime.library.?.programs.find(binding.setup).?);
        self.started = true;
    }

    // Run before the actor sweep; the caller applies recipient and damage events.
    pub fn advance(self: *State, runtime: *host.Runtime) !queue.Events {
        if (!self.started) return error.InvalidActorPlayback;
        var signals: [3]u16 = undefined;
        for (self.members, 0..) |actor, i| signals[i] = runtime.actors[actor].signals;
        const events = self.queue.advance(signals);
        for (self.members, 0..) |actor, i| {
            if (events.claims[i]) |enemy| {
                try runtime.dispatch(actor, self.enemies[enemy].?, runtime.library.?.programs.find(self.bindings[i].strike).?);
            } else if (events.returns & (@as(u3, 1) << @as(u2, @intCast(i))) != 0) {
                try runtime.dispatch(actor, null, runtime.library.?.programs.find(self.bindings[i].@"return").?);
            }
            runtime.actors[actor].signals &= ~events.consumed[i];
        }
        return events;
    }
};
